import Metal
import MetalKit
import QuartzCore
import UIKit

struct AnimationUniforms {
    var time: Float
    var duration: Float
    var travelDistance: Float
    var maxBlurInPixels: Float
    var viewportSize: SIMD2<Float>
    var layoutHeight: Float
    var atlasTexelSize: SIMD2<Float>
}

final class AnimationRenderer: NSObject {
    var onStats: ((PerformanceSnapshot) -> Void)?
    var onAnimationComplete: (() -> Void)?
    var onItemAnimationStart: ((CGFloat) -> Void)?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let horizontalPipelineState: MTLRenderPipelineState
    private let verticalPipelineState: MTLRenderPipelineState
    private var atlas: AnimationAtlas?
    private var instanceBuffer: MTLBuffer?
    private var horizontalTexture: MTLTexture?
    private var viewportSize = CGSize.zero
    private var layoutHeight: CGFloat = 0
    private var startTime = CACurrentMediaTime() + 0.15
    private var nextItemHeightIndex = 0
    /// 当前动画时间轴的起点，供 standalone view 把 delay 换算成实际等待时长。
    var timelineStartTime: CFTimeInterval { startTime }
    var debugInstanceCount: Int { atlas?.instances.count ?? 0 }
    private var performanceMonitor = PerformanceMonitor()

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        guard let commandQueue = device.makeCommandQueue() else {
            throw RendererError.commandQueueUnavailable
        }
        self.commandQueue = commandQueue

        guard let library = device.makeDefaultLibrary(),
              let horizontalVertex = library.makeFunction(name: "horizontalAnimationVertex"),
              let horizontalFragment = library.makeFunction(name: "animationHorizontalFragment"),
              let verticalVertex = library.makeFunction(name: "verticalAnimationVertex"),
              let verticalFragment = library.makeFunction(name: "animationVerticalFragment") else {
            throw RendererError.shaderUnavailable
        }

        let horizontalDescriptor = MTLRenderPipelineDescriptor()
        horizontalDescriptor.vertexFunction = horizontalVertex
        horizontalDescriptor.fragmentFunction = horizontalFragment
        horizontalDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        horizontalPipelineState = try device.makeRenderPipelineState(descriptor: horizontalDescriptor)

        let verticalDescriptor = MTLRenderPipelineDescriptor()
        verticalDescriptor.vertexFunction = verticalVertex
        verticalDescriptor.fragmentFunction = verticalFragment
        verticalDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        let verticalAttachment = verticalDescriptor.colorAttachments[0]!
        verticalAttachment.isBlendingEnabled = true
        verticalAttachment.rgbBlendOperation = .add
        verticalAttachment.alphaBlendOperation = .add
        verticalAttachment.sourceRGBBlendFactor = .one
        verticalAttachment.sourceAlphaBlendFactor = .one
        verticalAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        verticalAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        verticalPipelineState = try device.makeRenderPipelineState(descriptor: verticalDescriptor)
        super.init()
    }

    @discardableResult
    func layout(
        items: [MetalAnimationItem],
        font: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        maxBlur: Float,
        contentRect: CGRect,
        viewportSize: CGSize,
        contentScale: CGFloat,
        preservingTimeline: Bool
    ) throws -> [StandaloneViewLayout] {
        // 流式追加：保留 startTime 与旧实例的 delay，旧内容保持最终态不重播，
        // 新实例从当前已播时间（或队尾）接续。
        let elapsed = preservingTimeline ? Float(max(0, CACurrentMediaTime() - startTime)) : 0
        let atlas = try AnimationAtlasBuilder.build(
            items: items,
            font: font,
            textColor: textColor,
            lineSpacing: lineSpacing,
            maxBlur: maxBlur,
            contentRect: contentRect,
            viewportSize: viewportSize,
            contentScale: contentScale,
            existingDelays: preservingTimeline ? atlas?.sequenceDelays ?? [] : [],
            elapsed: elapsed,
            device: device
        )
        let byteCount = atlas.instances.count * MemoryLayout<AnimationInstance>.stride
        instanceBuffer = byteCount == 0 ? nil : device.makeBuffer(
            bytes: atlas.instances,
            length: byteCount,
            options: .storageModeShared
        )
        self.atlas = atlas
        self.viewportSize = viewportSize
        self.layoutHeight = viewportSize.height
        if !preservingTimeline { replay() }
        return atlas.standaloneViewLayouts
    }

    func updateViewportSize(_ viewportSize: CGSize) {
        self.viewportSize = viewportSize
    }

    func replay() {
        startTime = CACurrentMediaTime() + AnimationConfiguration.startDelay
        nextItemHeightIndex = 0
    }

    func draw(in view: MTKView) {
        guard let atlas else { return }
        let now = CACurrentMediaTime()
        let rawElapsed = Float(max(0, now - startTime))
        while nextItemHeightIndex < atlas.itemHeights.count {
            let itemHeight = atlas.itemHeights[nextItemHeightIndex]
            guard itemHeight.delay <= rawElapsed else { break }
            nextItemHeightIndex += 1
            onItemAnimationStart?(itemHeight.height)
        }
        let animationFinished = rawElapsed >= atlas.animationDuration

        if atlas.instances.isEmpty {
            if animationFinished { onAnimationComplete?() }
            return
        }
        guard let instanceBuffer,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let horizontalTexture = horizontalTexture(for: atlas) else {
            return
        }

        let horizontalPass = MTLRenderPassDescriptor()
        horizontalPass.colorAttachments[0].texture = horizontalTexture
        horizontalPass.colorAttachments[0].loadAction = .clear
        horizontalPass.colorAttachments[0].storeAction = .store
        horizontalPass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 0
        )
        guard let horizontalEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: horizontalPass
        ) else {
            return
        }

        let elapsed = min(rawElapsed, atlas.animationDuration)

        var uniforms = AnimationUniforms(
            time: elapsed,
            duration: AnimationConfiguration.duration,
            travelDistance: AnimationConfiguration.travelDistance,
            maxBlurInPixels: atlas.maxBlur * atlas.pixelsPerPoint,
            viewportSize: SIMD2(Float(viewportSize.width), Float(viewportSize.height)),
            layoutHeight: Float(layoutHeight),
            atlasTexelSize: SIMD2(
                1 / Float(atlas.texture.width),
                1 / Float(atlas.texture.height)
            )
        )

        horizontalEncoder.setRenderPipelineState(horizontalPipelineState)
        horizontalEncoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        horizontalEncoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<AnimationUniforms>.stride,
            index: 1
        )
        horizontalEncoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<AnimationUniforms>.stride,
            index: 1
        )
        horizontalEncoder.setFragmentTexture(atlas.texture, index: 0)
        horizontalEncoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: atlas.instances.count
        )
        horizontalEncoder.endEncoding()

        guard let verticalEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        ) else {
            return
        }
        verticalEncoder.setRenderPipelineState(verticalPipelineState)
        verticalEncoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        verticalEncoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<AnimationUniforms>.stride,
            index: 1
        )
        verticalEncoder.setFragmentTexture(horizontalTexture, index: 0)
        verticalEncoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: atlas.instances.count
        )
        verticalEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        let itemCount = atlas.instances.count + atlas.standaloneViewLayouts.count
        if let snapshot = performanceMonitor.frameRendered(at: now, itemCount: itemCount) {
            onStats?(snapshot)
        }
        if animationFinished {
            onAnimationComplete?()
        }
    }

    private func horizontalTexture(for atlas: AnimationAtlas) -> MTLTexture? {
        let width = Int(atlas.blurAtlasSize.width)
        let height = Int(atlas.blurAtlasSize.height)
        if let horizontalTexture,
           horizontalTexture.width == width,
           horizontalTexture.height == height {
            return horizontalTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        horizontalTexture = device.makeTexture(descriptor: descriptor)
        return horizontalTexture
    }
}

enum RendererError: LocalizedError {
    case commandQueueUnavailable
    case shaderUnavailable

    var errorDescription: String? {
        switch self {
        case .commandQueueUnavailable: return "无法创建 Metal 命令队列"
        case .shaderUnavailable: return "无法加载 Metal 着色器"
        }
    }
}
