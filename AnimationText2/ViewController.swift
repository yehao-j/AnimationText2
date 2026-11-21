import UIKit

final class ViewController: UIViewController {
    private var metalView: MetalTextView!
    private let statsLabel = UILabel()
    private let detailLabel = UILabel()
    private let standaloneIndicator = UIActivityIndicatorView(style: .medium)
    private var streamingBatches: [[MetalAnimationItem]] = []
    private var streamingWorkItem: DispatchWorkItem?
    private var appendRemainingAfterCompletion = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.965, green: 0.957, blue: 0.935, alpha: 1)
        
        let metalView = MetalTextView(frame: view.bounds, device: nil)
        metalView.heightBlock = {
            print("-----", $0)
        }
        metalView.layer.borderColor = UIColor.red.cgColor
        metalView.layer.borderWidth = 1
        metalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            metalView.topAnchor.constraint(equalTo: view.topAnchor, constant: 100),
            metalView.heightAnchor.constraint(equalToConstant: 500)
        ])
        self.metalView = metalView
        streamingBatches = DemoText.streamingBatches(
            staticViews: [
                makeStaticBadge(title: "UI", color: UIColor(red: 0.16, green: 0.48, blue: 0.78, alpha: 1)),
                makeStaticBadge(title: "GPU", color: UIColor(red: 0.84, green: 0.38, blue: 0.16, alpha: 1)),
                makeStaticBadge(title: "VIEW", color: UIColor(red: 0.32, green: 0.58, blue: 0.32, alpha: 1))
            ],
            standaloneView: makeStandaloneView(),
            standaloneIndicator: standaloneIndicator
        )

        configureHUD()
        metalView.onStats = { [weak self] snapshot in
            self?.statsLabel.text = String(
                format: "进程 CPU  %.1f%%   ·   %.0f FPS",
                snapshot.processCPU,
                snapshot.framesPerSecond
            )
            self?.detailLabel.text = "\(snapshot.itemCount) 个动画单元 · 2 draw calls/帧 · 单核 = 100%"
        }
        metalView.onAnimationComplete = { [weak self] in
            guard let self else { return }
            self.statsLabel.text = "动画已结束 · Metal 已暂停"
            guard self.appendRemainingAfterCompletion else { return }
            self.appendRemainingAfterCompletion = false
            self.appendRemainingItems()
        }
        metalView.onError = { [weak self] message in
            self?.showError(title: "排版失败", message: message)
        }
        if let error = metalView.initializationError {
            showError(title: "Metal 初始化失败", message: error)
        }
        startStreaming()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        metalView.layoutItemsIfNeeded()
    }

    private func startStreaming() {
        streamingWorkItem?.cancel()
        standaloneIndicator.stopAnimating()
        appendRemainingAfterCompletion = false
        guard streamingBatches.count > 1 else { return }
        metalView.items = streamingBatches[0]
        // 第一批还在播放时追加第二批，之后的追加等全部播完再延迟进行。
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.metalView.append(items: self.streamingBatches[1])
            self.appendRemainingAfterCompletion = true
        }
        streamingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func appendRemainingItems() {
        let remaining = streamingBatches.dropFirst(2).flatMap { $0 }
        let workItem = DispatchWorkItem { [weak self] in
            self?.metalView.append(items: remaining)
        }
        streamingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func makeStaticBadge(title: String, color: UIColor) -> UIView {
        let badge = UIView(frame: CGRect(x: 0, y: 0, width: 70, height: 20))
        badge.backgroundColor = color
        badge.layer.cornerRadius = 9
        badge.layer.borderWidth = 1
        badge.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor

        let label = UILabel()
        label.text = title
        label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ])
        return badge
    }

    private func makeStandaloneView() -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 260, height: 100))
        container.backgroundColor = UIColor(red: 0.16, green: 0.20, blue: 0.30, alpha: 1)
        container.layer.cornerRadius = 12
        container.clipsToBounds = true

        let indicator = standaloneIndicator
        indicator.color = .white
        indicator.hidesWhenStopped = false

        let label = UILabel()
        label.text = "原生 View 保留内部动画"
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white

        let stack = UIStackView(arrangedSubviews: [indicator, label])
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12)
        ])
        return container
    }

    private func configureHUD() {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.black.withAlphaComponent(0.86)
        container.layer.cornerRadius = 12
        view.addSubview(container)

        statsLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        statsLabel.textColor = .white
        statsLabel.text = "进程 CPU  采样中…"
        statsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        detailLabel.text = "GPU 位移 + 透明度 + 高斯模糊"

        let replayButton = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = "重新播放"
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        replayButton.configuration = configuration
        replayButton.addTarget(self, action: #selector(replay), for: .touchUpInside)

        let textStack = UIStackView(arrangedSubviews: [statsLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 5
        textStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(textStack)
        container.addSubview(replayButton)
        replayButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            textStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            textStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -10),
            replayButton.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 8),
            replayButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            replayButton.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
    }

    @objc private func replay() {
        statsLabel.text = "进程 CPU  采样中…"
        startStreaming()
    }

    private func showError(title: String, message: String) {
        statsLabel.text = title
        detailLabel.text = message
    }
}

private enum DemoText {
    /// 第一批是静态 View 前缀；正文在外部拆分后按 token 边界随机分成小批次，模拟 SSE 分片推送。
    static func streamingBatches(
        staticViews: [UIView],
        standaloneView: UIView,
        standaloneIndicator: UIActivityIndicatorView
    ) -> [[MetalAnimationItem]] {
        let prefix: [MetalAnimationItem] = [
            .text("汉"),
            .text("字"),
            .staticView(staticViews[0]),
            .text("与"),
            .text(" Metal "),
            .text("一起"),
            .text(" Animation"),
            .standaloneView(standaloneView, alignment: .left, completion: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    standaloneIndicator.startAnimating()
                }
            }),

            .text("单"),
            .text("词"),
            .staticView(staticViews[1]),
            .text("夹在"),
            .text(" Chinese "),
            .text("和"),
            .text(" UIKit "),
            .text("中间"),
            .text("\n"),

            .text("静"),
            .text("态"),
            .staticView(staticViews[2]),
            .text("也能"),
            .text("和"),
            .text(" Text "),
            .text("一起"),
            .text("出现"),
            .text("\n\n")
        ]

        let content = """
        外部按汉字或单词拆   分文本，内部保持整 段排版，再依次播放入场动画。

        文字、单词和静态快照共用位移、透明度与高斯模糊效果。
        Streaming tokens arrive over SSE, and each word animates as it lands.
        """
        let bodyItems = MetalAnimationItem.tokenize(content)
        var batches = [prefix]
        var index = 0
        while index < bodyItems.count {
            let count = Int.random(in: 1...3)
            batches.append(Array(bodyItems[index..<min(index + count, bodyItems.count)]))
            index += count
        }
        return batches
    }
}
