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
    var atlasTexelSize: SIMD2<Float>
}

final class TextRenderer: NSObject {
    var onStats: ((PerformanceSnapshot) -> Void)?
    var onAnimationComplete: (() -> Void)?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let horizontalPipelineState: MTLRenderPipelineState
    private let verticalPipelineState: MTLRenderPipelineState
    private var atlas: GlyphAtlas?
    private var instanceBuffer: MTLBuffer?
    private var horizontalTexture: MTLTexture?
    private var viewportSize = CGSize.zero
    private var startTime = CACurrentMediaTime() + 0.15
    private var performanceMonitor = PerformanceMonitor()

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        guard let commandQueue = device.makeCommandQueue() else {
            throw RendererError.commandQueueUnavailable
        }
        self.commandQueue = commandQueue

        guard let library = device.makeDefaultLibrary(),
              let textVertex = library.makeFunction(name: "textVertex"),
              let horizontalFragment = library.makeFunction(name: "textHorizontalFragment"),
              let fullscreenVertex = library.makeFunction(name: "fullscreenVertex"),
              let verticalFragment = library.makeFunction(name: "textVerticalFragment") else {
            throw RendererError.shaderUnavailable
        }

        let horizontalDescriptor = MTLRenderPipelineDescriptor()
        horizontalDescriptor.vertexFunction = textVertex
        horizontalDescriptor.fragmentFunction = horizontalFragment
        horizontalDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let horizontalAttachment = horizontalDescriptor.colorAttachments[0]!
        horizontalAttachment.isBlendingEnabled = true
        horizontalAttachment.rgbBlendOperation = .max
        horizontalAttachment.alphaBlendOperation = .min
        horizontalPipelineState = try device.makeRenderPipelineState(descriptor: horizontalDescriptor)

        let verticalDescriptor = MTLRenderPipelineDescriptor()
        verticalDescriptor.vertexFunction = fullscreenVertex
        verticalDescriptor.fragmentFunction = verticalFragment
        verticalDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        let verticalAttachment = verticalDescriptor.colorAttachments[0]!
        verticalAttachment.isBlendingEnabled = true
        verticalAttachment.rgbBlendOperation = .add
        verticalAttachment.alphaBlendOperation = .add
        verticalAttachment.sourceRGBBlendFactor = .sourceAlpha
        verticalAttachment.sourceAlphaBlendFactor = .sourceAlpha
        verticalAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        verticalAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        verticalPipelineState = try device.makeRenderPipelineState(descriptor: verticalDescriptor)
        super.init()
    }

    func layout(
        text: String,
        font: UIFont,
        lineSpacing: CGFloat,
        maxBlur: Float,
        contentRect: CGRect,
        viewportSize: CGSize,
        contentScale: CGFloat
    ) throws {
        let atlas = try GlyphAtlasBuilder.build(
            text: text,
            font: font,
            lineSpacing: lineSpacing,
            maxBlur: maxBlur,
            contentRect: contentRect,
            contentScale: contentScale,
            device: device
        )
        let byteCount = atlas.instances.count * MemoryLayout<GlyphInstance>.stride
        instanceBuffer = device.makeBuffer(
            bytes: atlas.instances,
            length: byteCount,
            options: .storageModeShared
        )
        self.atlas = atlas
        self.viewportSize = viewportSize
        replay()
    }

    func replay() {
        startTime = CACurrentMediaTime() + 0.08
    }

    func draw(in view: MTKView) {
        guard let atlas,
              let instanceBuffer,
              !atlas.instances.isEmpty,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let horizontalTexture = horizontalTexture(for: drawable.texture) else {
            return
        }

        let horizontalPass = MTLRenderPassDescriptor()
        horizontalPass.colorAttachments[0].texture = horizontalTexture
        horizontalPass.colorAttachments[0].loadAction = .clear
        horizontalPass.colorAttachments[0].storeAction = .store
        horizontalPass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1
        )
        guard let horizontalEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: horizontalPass
        ) else {
            return
        }

        let now = CACurrentMediaTime()
        let rawElapsed = Float(max(0, now - startTime))
        let animationFinished = rawElapsed >= atlas.animationDuration
        let elapsed = min(rawElapsed, atlas.animationDuration)

        var uniforms = AnimationUniforms(
            time: elapsed,
            duration: TextAnimation.duration,
            travelDistance: TextAnimation.travelDistance,
            maxBlurInPixels: atlas.maxBlur * atlas.pixelsPerPoint,
            viewportSize: SIMD2(Float(viewportSize.width), Float(viewportSize.height)),
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
        verticalEncoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<AnimationUniforms>.stride,
            index: 1
        )
        verticalEncoder.setFragmentTexture(horizontalTexture, index: 0)
        verticalEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        verticalEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        if let snapshot = performanceMonitor.frameRendered(at: now, glyphCount: atlas.instances.count) {
            onStats?(snapshot)
        }
        if animationFinished {
            onAnimationComplete?()
        }
    }

    private func horizontalTexture(for drawable: MTLTexture) -> MTLTexture? {
        if let horizontalTexture,
           horizontalTexture.width == drawable.width,
           horizontalTexture.height == drawable.height {
            return horizontalTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: drawable.width,
            height: drawable.height,
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
