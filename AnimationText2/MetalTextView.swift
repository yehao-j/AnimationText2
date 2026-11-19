import MetalKit
import UIKit

public enum MetalAnimationItem {
    case text(String)
    /// 垂直位置自动与相邻文本行的墨迹中心对齐，x 与 size 只决定水平位置和尺寸；size.height 不能超过行高。
    case staticView(UIView, x: CGFloat, size: CGSize)
}

public final class MetalTextView: MTKView, MTKViewDelegate {
    public var onStats: ((PerformanceSnapshot) -> Void)?
    public var onAnimationComplete: (() -> Void)?
    public var onError: ((String) -> Void)?
    public private(set) var initializationError: String?

    public var items: [MetalAnimationItem] = [] {
        didSet { invalidateContentLayout() }
    }
    /// 行高 = font.lineHeight + lineSpacing。修改任一配置都会重新排版并重建图集。
    public var font = AnimationConfiguration.font {
        didSet { invalidateContentLayout() }
    }
    public var textColor: UIColor = UIColor(red: 0.09, green: 0.10, blue: 0.11, alpha: 1) {
        didSet { invalidateContentLayout() }
    }
    public var lineSpacing: CGFloat = AnimationConfiguration.lineSpacing {
        didSet { invalidateContentLayout() }
    }
    /// 最大模糊半径（pt）。0 表示无模糊。
    public var maxBlur: Float = 8 {
        didSet { invalidateContentLayout() }
    }

    private var renderer: AnimationRenderer?
    private var lastContentRect = CGRect.null
    private var lastContentScale: CGFloat = 0

    public override init(frame frameRect: CGRect, device: MTLDevice?) {
        let metalDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: metalDevice)
        guard let metalDevice else {
            initializationError = "这台设备不支持 Metal"
            return
        }
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.965, green: 0.957, blue: 0.935, alpha: 1)
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        delegate = self

        do {
            let renderer = try AnimationRenderer(device: metalDevice, pixelFormat: colorPixelFormat)
            renderer.onStats = { [weak self] snapshot in
                self?.onStats?(snapshot)
            }
            renderer.onAnimationComplete = { [weak self] in
                self?.isPaused = true
                self?.onAnimationComplete?()
            }
            self.renderer = renderer
        } catch {
            initializationError = error.localizedDescription
        }
    }

    public required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func layoutItemsIfNeeded() {
        guard let renderer, !items.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        let insets = safeAreaInsets
        let horizontalMargin: CGFloat = 22
        let top = insets.top + 18
        let bottom = insets.bottom + 108
        let contentRect = CGRect(
            x: horizontalMargin,
            y: bottom,
            width: bounds.width - horizontalMargin * 2,
            height: bounds.height - top - bottom
        )
        guard contentRect.width > 0, contentRect.height > 0 else { return }
        guard contentRect != lastContentRect || contentScaleFactor != lastContentScale else { return }

        do {
            try renderer.layout(
                items: items,
                font: font,
                textColor: textColor,
                lineSpacing: lineSpacing,
                maxBlur: maxBlur,
                contentRect: contentRect,
                viewportSize: bounds.size,
                contentScale: contentScaleFactor
            )
            lastContentRect = contentRect
            lastContentScale = contentScaleFactor
            isPaused = false
        } catch {
            onError?(error.localizedDescription)
        }
    }

    public func replay() {
        guard let renderer else { return }
        renderer.replay()
        isPaused = false
    }

    private func invalidateContentLayout() {
        lastContentRect = .null
        layoutItemsIfNeeded()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        layoutItemsIfNeeded()
    }

    public func draw(in view: MTKView) {
        renderer?.draw(in: view)
    }
}
