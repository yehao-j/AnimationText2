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
    /// 垂直位置自动与相邻文本行的墨迹中心对齐，x 与 size 只决定水平位置和尺寸；高度超过行高时只显示顶部行高部分。
    case staticView(UIView, x: CGFloat, size: CGSize)
    /// 原生 View 独占一行并按 alignment 对齐，宽度夹紧到 MetalTextView 宽度；保留内部动画，仅执行上移动画。
    case standaloneView(
        UIView,
        size: CGSize,
        alignment: MetalStandaloneViewAlignment = .center
    )
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

    private var renderer: AnimationRenderer?
    private var lastContentRect = CGRect.null
    private var lastContentScale: CGFloat = 0
    private var standaloneViewLayouts: [StandaloneViewLayout] = []
    private var timelineStartTime = CACurrentMediaTime()
    private var standaloneContainers: [ObjectIdentifier: UIView] = [:]
    private var standaloneAnimators: [ObjectIdentifier: UIViewPropertyAnimator] = [:]
    private var standaloneStartWorkItems: [ObjectIdentifier: DispatchWorkItem] = [:]

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
            print("[MTV] layout preserving=\(preservingTimeline) rect=\(contentRect) bounds=\(bounds) safe=\(safeAreaInsets) items=\(items.count) instances=\(renderer.debugInstanceCount) standalone=\(standaloneViewLayouts.map { $0.frame })")
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
            // 续接时旧 view 的待启动任务和进行中的动画都保持不动，只更新布局。
            if !preservingTimeline || newIdentifiers.contains(identifier) {
                standaloneStartWorkItems[identifier]?.cancel()
                standaloneAnimators[identifier]?.stopAnimation(true)
                container.transform = .identity
            }
            container.bounds.size = layout.frame.size
            container.center = CGPoint(x: layout.frame.midX, y: layout.frame.midY)
            print("[MTV] standalone set frame=\(layout.frame) actual=\(container.frame) transform=\(container.transform) preserving=\(preservingTimeline)")
            layout.view.bounds.size = container.bounds.size
            layout.view.center = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
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
            guard let container = standaloneContainers[identifier] else { continue }
            standaloneStartWorkItems[identifier]?.cancel()
            standaloneAnimators[identifier]?.stopAnimation(true)
            container.isHidden = true
            container.transform = CGAffineTransform(
                translationX: 0,
                y: CGFloat(AnimationConfiguration.travelDistance)
            )
            let animator = UIViewPropertyAnimator(
                duration: TimeInterval(AnimationConfiguration.duration),
                curve: .easeOut
            ) {
                container.transform = .identity
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
    }

    public func draw(in view: MTKView) {
        renderer?.draw(in: view)
    }
}
