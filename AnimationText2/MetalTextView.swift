import MetalKit
import UIKit

public final class MetalTextView: MTKView, MTKViewDelegate {
    public var onStats: ((PerformanceSnapshot) -> Void)?
    public var onAnimationComplete: (() -> Void)?
    public var onError: ((String) -> Void)?
    public private(set) var initializationError: String?

    /// 行高 = font.lineHeight + lineSpacing。修改任一配置都会重新排版并重建图集。
    public var font = UIFont.systemFont(ofSize: 17, weight: .regular) {
        didSet { invalidateTextLayout() }
    }
    public var lineSpacing: CGFloat = 7 {
        didSet { invalidateTextLayout() }
    }
    /// 最大模糊半径（pt）。0 表示无模糊。
    public var maxBlur: Float = 8 {
        didSet { invalidateTextLayout() }
    }

    private var renderer: TextRenderer?
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
            let renderer = try TextRenderer(device: metalDevice, pixelFormat: colorPixelFormat)
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

    public func layoutTextIfNeeded() {
        guard let renderer, bounds.width > 0, bounds.height > 0 else { return }
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
                text: DemoText.content,
                font: font,
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

    private func invalidateTextLayout() {
        lastContentRect = .null
        layoutTextIfNeeded()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        layoutTextIfNeeded()
    }

    public func draw(in view: MTKView) {
        renderer?.draw(in: view)
    }
}

private enum DemoText {
    private static let paragraphs = """
    这次轻松跑完成了 4 km，平均配速 8'43\"/km，是一场节奏偏慢、把身体带动的短距离训练。步频和功率同步下降，后程更像是主动放缓而非硬撑；心率分布以有氧区间为主，身体的状态保持得不错。

    从分段看，第 3 到第 4 公里配速从 9'30\"/km 逐渐放到 11'14\"/km。跑后一分钟心率没有明显回落，说明这次结束时身体仍处在活动状态。下一次可以把前十分钟控制在更轻的负担，让呼吸、步幅和节奏自然衔接。

    Metal 把每一个字看作一个独立实例。字形位置、纹理坐标和出现延迟只在布局时计算一次；动画期间，顶点着色器根据当前时间计算上移和透明度。整屏字形共用一次实例化绘制，再通过横向、纵向两趟可分离高斯完成模糊，不需要逐字修改图层，也不需要每帧在 CPU 上重新排版。

    观察性能时可以留意稳定阶段，而不是首次生成字形图集的瞬间。Core Text 排版和位图栅格化只发生在尺寸变化时。动画期间，每帧只更新很短的时间参数，剩余工作交给 GPU；未开始的文字不会产生片元，完全清晰后两趟都只读取一次纹理，结束后暂停渲染。
    """

    static let content = Array(repeating: paragraphs, count: 3).joined(separator: "\n\n")
}
