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
    /// 作为行内元素紧跟前一个元素排版，直接读取 view.bounds.size，并在当前行内垂直居中；
    /// spacing 为 view 两侧各留出的间距。view 是首个 item 时不加左侧间距；右侧间距用行尾空格
    /// 实现，view 排到行尾时间距悬挂不显示，也不会把 view 挤到下一行。
    /// 保留原生 UIKit 内部动画（如指示器旋转）；入场动画与 standaloneView 同款由 UIKit 按时间轴播放，
    /// 播完回调 completion（流式追加不重播旧内容，不会重复回调）。
    case inlineView(
        UIView,
        spacing: CGFloat = 0,
        completion: (() -> Void)? = nil
    )
    /// 原生 View 独占一行并按 alignment 对齐；直接读取 view.bounds.size，宽度夹紧到 MetalAnimationView 宽度。
    case standaloneView(
        UIView,
        alignment: MetalStandaloneViewAlignment = .center,
        completion: (() -> Void)? = nil
    )
    /// 标记流式内容结束；不参与排版，各 contentView 自身动画完成后触发 onAnimationComplete。
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

public final class MetalAnimationView: UIView {
    private var metalViews: [MetalContentView] = []
    private let contentHeight: CGFloat
    private let device: MTLDevice?
    private var renderer: AnimationRenderer?
    private var storedItems: [MetalAnimationItem] = []
    private var lastContentScale: CGFloat = 0
    private var timelineStartTime = CACurrentMediaTime()
    private var renderedContentHeight: CGFloat = 0
    private var lastReportedContentHeight: CGFloat?
    private var completedSegmentIndexes: Set<Int> = []

    private enum PendingLayout {
        case append
        case rebuild
    }
    private var pendingLayout: PendingLayout?
    private var appendLayoutScheduled = false

    public var onStats: ((PerformanceSnapshot) -> Void)?
    /// 收到 end 后，每个 contentView 自身动画全部完成时各回调一次（参数为 contentView 序号）；
    /// 最后一次回调时视图高度已调整为内容高度。
    public var onAnimationComplete: ((Int) -> Void)?
    /// 每行首个 item 渲染前回调截至该行的累计高度，相同高度不重复回调。
    public var onRenderedContentHeight: ((CGFloat) -> Void)?
    public var onError: ((String) -> Void)?
    public private(set) var initializationError: String?

    /// 整段设置会重置内容并从头播放；流式追加请用 `append(items:)`。
    public var items: [MetalAnimationItem] {
        get { storedItems }
        set {
            storedItems = newValue
            invalidateContentLayout()
        }
    }
    public override var backgroundColor: UIColor? {
        didSet { metalViews.forEach { $0.backgroundColor = backgroundColor } }
    }
    /// 文本颜色；修改后重新排版并从头播放。
    public var textColor = UIColor(red: 0.09, green: 0.10, blue: 0.11, alpha: 1) {
        didSet { invalidateContentLayout() }
    }
    /// 文本字体；修改后重新排版并从头播放。
    public var font = UIFont.systemFont(ofSize: 17, weight: .regular) {
        didSet { invalidateContentLayout() }
    }
    /// 普通文本行的行高，为当前字体行高向上取整，单位为点。
    private var lineHeight: CGFloat { ceil(font.lineHeight) }
    /// 字符间距，单位为点；修改后重新排版并从头播放。
    public var letterSpacing: CGFloat = 0 {
        didSet { invalidateContentLayout() }
    }
    /// 相邻文本行之间的额外间距，单位为点；修改后重新排版并从头播放。
    public var lineSpacing: CGFloat = 0 {
        didSet { invalidateContentLayout() }
    }
    /// 是否为每个文本行绘制随机背景色；颜色生成后保持不变，透明度为 0.5。修改后重新排版并从头播放。
    public var showsRandomLineColors = true {
        didSet { invalidateContentLayout() }
    }

    public init(frame frameRect: CGRect, height: CGFloat, device: MTLDevice?) {
        // 排版宽度与单个 Metal 画布高度在创建时确定且不再变化，必须传入有效值。
        precondition(frameRect.width > 0, "MetalAnimationView 需要有效的 frame，width 不能为 0")
        precondition(height > 0, "MetalAnimationView 需要有效的 height，height 不能为 0")
        contentHeight = height
        let metalDevice = device ?? MTLCreateSystemDefaultDevice()
        self.device = metalDevice
        if let metalDevice {
            do {
                renderer = try AnimationRenderer(device: metalDevice, pixelFormat: .bgra8Unorm)
            } catch {
                initializationError = error.localizedDescription
            }
        } else {
            initializationError = "这台设备不支持 Metal"
        }
        super.init(frame: frameRect)
        clipsToBounds = true
        configureRenderer()
        appendMetalView()
    }

    public required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 流式追加 item（文本拆分由外部完成）。已显示的内容不重播，新 item 接续当前动画
    /// 时间轴；同一 runloop 内的多次追加合并为一次排版重建。需在主线程调用。
    public func append(items newItems: [MetalAnimationItem]) {
        guard !newItems.isEmpty else { return }
        storedItems.append(contentsOf: newItems)
        pendingLayout = .append
        guard !appendLayoutScheduled else { return }
        appendLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appendLayoutScheduled = false
            self.layoutItemsIfNeeded()
        }
    }

    public func layoutItemsIfNeeded() {
        guard let renderer, !items.isEmpty, bounds.width > 0, contentHeight > 0 else { return }
        let contentScale = metalViews[0].contentScaleFactor
        guard pendingLayout != nil || contentScale != lastContentScale else { return }
        let preservingTimeline = pendingLayout == .append

        do {
            let contentSegments = try renderer.layout(
                items: items,
                font: font,
                lineHeight: lineHeight,
                textColor: textColor,
                letterSpacing: letterSpacing,
                lineSpacing: lineSpacing,
                showsRandomLineColors: showsRandomLineColors,
                maxBlur: AnimationConfiguration.maxBlur,
                contentRect: CGRect(x: 0, y: 0, width: bounds.width, height: contentHeight),
                viewportSize: CGSize(width: bounds.width, height: contentHeight),
                contentScale: contentScale,
                preservingTimeline: preservingTimeline
            )
            timelineStartTime = renderer.timelineStartTime
            updateMetalViews(with: contentSegments, preservingTimeline: preservingTimeline)
            lastContentScale = contentScale
            pendingLayout = nil
        } catch {
            onError?(error.localizedDescription)
        }
    }

    public func replay() {
        invalidateContentLayout()
    }

    private func configureRenderer() {
        renderer?.onStats = { [weak self] snapshot in
            self?.onStats?(snapshot)
        }
        renderer?.onAnimationComplete = { [weak self] segmentIndex in
            guard let self else { return }
            self.completedSegmentIndexes.insert(segmentIndex)
            // 序号 0 的 contentView 负责驱动整体事件（高度回调、性能统计），
            // 要等所有分段都完成后才能暂停，因此不在这里单独停掉它。
            if segmentIndex != 0, self.metalViews.indices.contains(segmentIndex) {
                self.metalViews[segmentIndex].isPaused = true
            }
            self.onAnimationComplete?(segmentIndex)
            print("contentView \(segmentIndex) 动画完成，MetalAnimationView 整体高度：", self.renderedContentHeight)
            if self.completedSegmentIndexes.count == self.metalViews.count {
                self.metalViews.forEach { $0.isPaused = true }
            }
        }
        renderer?.onItemAnimationStart = { [weak self] height in
            guard let self else { return }
            self.renderedContentHeight = height
            guard self.lastReportedContentHeight != height else { return }
            self.lastReportedContentHeight = height
            self.frame.size.height = height
            self.onRenderedContentHeight?(height)
        }
    }

    @discardableResult
    private func appendMetalView() -> MetalContentView {
        let index = metalViews.count
        let metalView = MetalContentView(
            frame: CGRect(x: 0, y: 0, width: bounds.width, height: contentHeight),
            device: device,
            renderer: renderer,
            segmentIndex: index
        )
        
        metalView.backgroundColor = backgroundColor
        metalView.onNeedsLayout = { [weak self] in
            self?.layoutItemsIfNeeded()
        }
        metalViews.append(metalView)
        addSubview(metalView)
        return metalView
    }

    private func updateMetalViews(
        with contentSegments: [AnimationContentSegment],
        preservingTimeline: Bool
    ) {
        completedSegmentIndexes.removeAll()
        while metalViews.count < contentSegments.count {
            appendMetalView()
        }
        while metalViews.count > contentSegments.count {
            metalViews.removeLast().removeFromSuperview()
        }
        var y: CGFloat = 0
        for (index, segment) in contentSegments.enumerated() {
            let metalView = metalViews[index]
            metalView.frame.origin.y = y
            metalView.applyStandaloneViewLayouts(
                segment.standaloneViewLayouts,
                timelineStartTime: timelineStartTime,
                preservingTimeline: preservingTimeline
            )
            metalView.isPaused = false
            y += segment.visibleHeight + lineSpacing
        }
    }

    private func invalidateContentLayout() {
        pendingLayout = .rebuild
        renderedContentHeight = 0
        layoutItemsIfNeeded()
    }
}

private final class MetalContentView: MTKView, MTKViewDelegate {
    var onNeedsLayout: (() -> Void)?
    private let renderer: AnimationRenderer?
    private let segmentIndex: Int
    private var standaloneViewLayouts: [StandaloneViewLayout] = []
    private var timelineStartTime = CACurrentMediaTime()
    private var standaloneContainers: [ObjectIdentifier: UIView] = [:]
    private var standaloneBlurViews: [ObjectIdentifier: UIVisualEffectView] = [:]
    private var standaloneAnimators: [ObjectIdentifier: UIViewPropertyAnimator] = [:]
    private var standaloneStartWorkItems: [ObjectIdentifier: DispatchWorkItem] = [:]

    init(
        frame frameRect: CGRect,
        device: MTLDevice?,
        renderer: AnimationRenderer?,
        segmentIndex: Int
    ) {
        self.renderer = renderer
        self.segmentIndex = segmentIndex
        super.init(frame: frameRect, device: device)
        colorPixelFormat = .bgra8Unorm
        clipsToBounds = true
        clearColor = MTLClearColor(red: 0.965, green: 0.957, blue: 0.935, alpha: 1)
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        delegate = self
    }

    public required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        standaloneStartWorkItems.values.forEach { $0.cancel() }
        standaloneAnimators.values.forEach { $0.stopAnimation(true) }
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

    func applyStandaloneViewLayouts(
        _ layouts: [StandaloneViewLayout],
        timelineStartTime: CFTimeInterval,
        preservingTimeline: Bool
    ) {
        standaloneViewLayouts = layouts
        self.timelineStartTime = timelineStartTime
        layoutStandaloneViews(preservingTimeline: preservingTimeline)
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
            blurView.effect = AnimationConfiguration.maxBlur > 0 ? UIBlurEffect(style: .regular) : nil
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

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        onNeedsLayout?()
        if isPaused {
            draw(in: view)
        }
    }

    public func draw(in view: MTKView) {
        renderer?.draw(in: view, segmentIndex: segmentIndex, reportsEvents: segmentIndex == 0)
    }
}
