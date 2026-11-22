import MetalKit
import QuartzCore
import UIKit

public enum MetalStandaloneViewAlignment {
    case left
    case center
    case right
}

public enum MetalAnimationItem {
    case text(String)
    /// 作为行内元素紧跟前一个元素排版，直接读取 view.bounds.size，并在当前行内垂直居中。
    case staticView(UIView)
    /// 原生 View 独占一行并按 alignment 对齐；直接读取 view.bounds.size，宽度夹紧到 MetalTextView 宽度。
    case standaloneView(
        UIView,
        alignment: MetalStandaloneViewAlignment = .center,
        completion: (() -> Void)? = nil
    )
    /// 标记流式内容结束；不参与排版，全部动画完成后触发 onAnimationComplete。
    case end
}

public extension MetalAnimationItem {
    /// 把一段文本拆成动画单元：英文/数字按单词，汉字、标点及其他符号逐字，连续空白合并为一个单元。
    /// 空白单元只参与排版占位，没有可见字形，因此不生成动画实例、不占动画时间槽位。
    static func tokenize(_ text: String) -> [MetalAnimationItem] {
        var items: [MetalAnimationItem] = []
        var word = ""
        var whitespace = ""

        func flushWord() {
            guard !word.isEmpty else { return }
            items.append(.text(word))
            word = ""
        }
        func flushWhitespace() {
            guard !whitespace.isEmpty else { return }
            items.append(.text(whitespace))
            whitespace = ""
        }

        for character in text {
            if character.isWhitespace {
                flushWord()
                whitespace.append(character)
            } else if character.isWordCharacter {
                flushWhitespace()
                word.append(character)
            } else {
                flushWord()
                flushWhitespace()
                items.append(.text(String(character)))
            }
        }
        flushWord()
        flushWhitespace()
        return items
    }
}

private extension Character {
    var isWordCharacter: Bool {
        guard isLetter || isNumber else { return false }
        return !unicodeScalars.contains { $0.isCJKIdeograph }
    }
}

private extension Unicode.Scalar {
    var isCJKIdeograph: Bool {
        switch value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2A6DF, 0x2A700...0x2EBEF:
            return true
        default:
            return false
        }
    }
}

public final class MetalTextView: MTKView, MTKViewDelegate {
    public var onStats: ((PerformanceSnapshot) -> Void)?
    public var onAnimationComplete: (() -> Void)?
    public var onError: ((String) -> Void)?
    /// item 开始动画时回调截至当前行的累计高度，相同高度不重复回调。
    public var heightBlock: ((CGFloat) -> Void)?
    public private(set) var initializationError: String?

    private var storedItems: [MetalAnimationItem] = []
    /// 整段设置会重置内容并从头播放；流式追加请用 `append(items:)`。
    public var items: [MetalAnimationItem] {
        get { storedItems }
        set {
            storedItems = newValue
            invalidateContentLayout()
        }
    }
    private var pendingAppend = false
    private var appendLayoutScheduled = false

    /// 流式追加 item（文本拆分由外部完成）。已显示的内容不重播，新 item 接续当前动画
    /// 时间轴；同一 runloop 内的多次追加合并为一次排版重建。需在主线程调用。
    public func append(items newItems: [MetalAnimationItem]) {
        guard !newItems.isEmpty else { return }
        storedItems.append(contentsOf: newItems)
        pendingAppend = true
        guard !appendLayoutScheduled else { return }
        appendLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appendLayoutScheduled = false
            self.layoutItemsIfNeeded()
        }
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
    public override var backgroundColor: UIColor? {
        didSet {
            guard let backgroundColor else {
                clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                return
            }
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            guard backgroundColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            clearColor = MTLClearColor(
                red: Double(red),
                green: Double(green),
                blue: Double(blue),
                alpha: Double(alpha)
            )
        }
    }

    private var renderer: AnimationRenderer?
    private var lastContentRect = CGRect.null
    private var lastContentScale: CGFloat = 0
    private var standaloneViewLayouts: [StandaloneViewLayout] = []
    private var timelineStartTime = CACurrentMediaTime()
    private var standaloneContainers: [ObjectIdentifier: UIView] = [:]
    private var standaloneBlurViews: [ObjectIdentifier: UIVisualEffectView] = [:]
    private var standaloneAnimators: [ObjectIdentifier: UIViewPropertyAnimator] = [:]
    private var standaloneStartWorkItems: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var lastHeightBlockValue: CGFloat?

    public override init(frame frameRect: CGRect, device: MTLDevice?) {
        let metalDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: metalDevice)
        guard let metalDevice else {
            initializationError = "这台设备不支持 Metal"
            return
        }
        colorPixelFormat = .bgra8Unorm
        clipsToBounds = true
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
            renderer.onItemAnimationStart = { [weak self] height in
                guard let self, let heightBlock = self.heightBlock,
                      self.lastHeightBlockValue != height else { return }
                self.lastHeightBlockValue = height
                heightBlock(height)
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
        let contentRect = bounds
        guard contentRect.width > 0, contentRect.height > 0 else { return }
        if !pendingAppend,
           contentRect.origin == lastContentRect.origin,
           contentRect.width == lastContentRect.width,
           contentRect.height != lastContentRect.height,
           contentScaleFactor == lastContentScale {
            // 仅高度变化时沿用图集和 standalone frame，按高度差平移实例以保持顶部位置。
            renderer.updateViewportSize(bounds.size)
            lastContentRect = contentRect
            return
        }
        guard pendingAppend || contentRect != lastContentRect || contentScaleFactor != lastContentScale else { return }
        let preservingTimeline = pendingAppend

        do {
            standaloneViewLayouts = try renderer.layout(
                items: items,
                font: font,
                textColor: textColor,
                lineSpacing: lineSpacing,
                maxBlur: maxBlur,
                contentRect: contentRect,
                viewportSize: bounds.size,
                contentScale: contentScaleFactor,
                preservingTimeline: preservingTimeline
            )
            timelineStartTime = renderer.timelineStartTime
            layoutStandaloneViews(preservingTimeline: preservingTimeline)
            lastContentRect = contentRect
            lastContentScale = contentScaleFactor
            pendingAppend = false
            isPaused = false
        } catch {
            onError?(error.localizedDescription)
        }
    }

    public func replay() {
        invalidateContentLayout()
    }

    private func layoutStandaloneViews(preservingTimeline: Bool) {
        let validIdentifiers = Set(standaloneViewLayouts.map { ObjectIdentifier($0.view) })
        let staleIdentifiers = standaloneContainers.keys.filter { !validIdentifiers.contains($0) }
        for identifier in staleIdentifiers {
            standaloneStartWorkItems[identifier]?.cancel()
            standaloneAnimators[identifier]?.stopAnimation(true)
            standaloneContainers[identifier]?.removeFromSuperview()
            standaloneContainers.removeValue(forKey: identifier)
            standaloneBlurViews.removeValue(forKey: identifier)
            standaloneAnimators.removeValue(forKey: identifier)
            standaloneStartWorkItems.removeValue(forKey: identifier)
        }

        var newIdentifiers = Set<ObjectIdentifier>()
        for layout in standaloneViewLayouts {
            let identifier = ObjectIdentifier(layout.view)
            let container: UIView
            if let existingContainer = standaloneContainers[identifier] {
                container = existingContainer
            } else {
                container = UIView()
                container.isHidden = true
                container.addSubview(layout.view)
                addSubview(container)
                standaloneContainers[identifier] = container
                newIdentifiers.insert(identifier)
            }
            let blurView: UIVisualEffectView
            if let existing = standaloneBlurViews[identifier] {
                blurView = existing
            } else {
                blurView = UIVisualEffectView()
                blurView.isUserInteractionEnabled = false
                container.addSubview(blurView)
                standaloneBlurViews[identifier] = blurView
            }
            // 模糊层默认是直角矩形，会盖住 view 自身的圆角；跟随 view 的圆角设置。
            blurView.layer.cornerRadius = layout.view.layer.cornerRadius
            blurView.layer.cornerCurve = layout.view.layer.cornerCurve
            blurView.clipsToBounds = true
            // 续接时旧 view 的待启动任务和进行中的动画都保持不动，只更新布局。
            if !preservingTimeline || newIdentifiers.contains(identifier) {
                standaloneStartWorkItems[identifier]?.cancel()
                standaloneAnimators[identifier]?.stopAnimation(true)
                container.transform = .identity
            }
            container.bounds.size = layout.frame.size
            container.center = CGPoint(x: layout.frame.midX, y: layout.frame.midY)
            layout.view.center = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
            blurView.frame = container.bounds
            layout.view.setNeedsLayout()
            layout.view.layoutIfNeeded()
        }
        replayStandaloneViews(newIdentifiers: preservingTimeline ? newIdentifiers : nil)
    }

    /// newIdentifiers 为 nil 时全部重播；否则只播放本次新增的 view，已显示的保持原状。
    private func replayStandaloneViews(newIdentifiers: Set<ObjectIdentifier>?) {
        for layout in standaloneViewLayouts {
            let identifier = ObjectIdentifier(layout.view)
            if let newIdentifiers, !newIdentifiers.contains(identifier) { continue }
            guard let container = standaloneContainers[identifier],
                  let blurView = standaloneBlurViews[identifier] else { continue }
            standaloneStartWorkItems[identifier]?.cancel()
            standaloneAnimators[identifier]?.stopAnimation(true)
            container.isHidden = true
            container.alpha = 0
            blurView.effect = maxBlur > 0 ? UIBlurEffect(style: .regular) : nil
            container.transform = CGAffineTransform(
                translationX: 0,
                y: CGFloat(AnimationConfiguration.travelDistance)
            )
            let animator = UIViewPropertyAnimator(
                duration: TimeInterval(AnimationConfiguration.duration),
                curve: .linear
            ) {
                container.alpha = 1
                container.transform = .identity
                blurView.effect = nil
            }
            animator.addCompletion { position in
                guard position == .end else { return }
                layout.completion?()
            }
            let startWorkItem = DispatchWorkItem {
                container.isHidden = false
                animator.startAnimation()
            }
            standaloneAnimators[identifier] = animator
            standaloneStartWorkItems[identifier] = startWorkItem
            // layout.delay 是相对 renderer 时间轴起点的时刻，换算成相对现在的等待时长，
            // 保证 standalone view 与 GPU 实例同步（重置与追加都适用）。
            let delay = max(0, timelineStartTime + TimeInterval(layout.delay) - CACurrentMediaTime())
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: startWorkItem)
        }
    }

    private func invalidateContentLayout() {
        pendingAppend = false
        lastContentRect = .null
        layoutItemsIfNeeded()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        layoutItemsIfNeeded()
        if isPaused {
            draw(in: view)
        }
    }

    public func draw(in view: MTKView) {
        renderer?.draw(in: view)
    }
}
