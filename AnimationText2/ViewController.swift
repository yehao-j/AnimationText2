import UIKit

final class ViewController: UIViewController {
    private var metalView: MetalTextView!
    private let statsLabel = UILabel()
    private let detailLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.965, green: 0.957, blue: 0.935, alpha: 1)

        let metalView = MetalTextView(frame: view.bounds, device: nil)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: view.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.metalView = metalView

        configureHUD()
        metalView.onStats = { [weak self] snapshot in
            self?.statsLabel.text = String(
                format: "进程 CPU  %.1f%%   ·   %.0f FPS",
                snapshot.processCPU,
                snapshot.framesPerSecond
            )
            self?.detailLabel.text = "\(snapshot.glyphCount) 字 · 2 draw calls/帧 · 单核 = 100%"
        }
        metalView.onAnimationComplete = { [weak self] in
            self?.statsLabel.text = "动画已结束 · Metal 已暂停"
        }
        metalView.onError = { [weak self] message in
            self?.showError(message)
        }
        if let error = metalView.initializationError {
            showError(error)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        metalView.layoutTextIfNeeded()
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
        metalView.replay()
    }

    private func showError(_ message: String) {
        statsLabel.text = "Metal 初始化失败"
        detailLabel.text = message
    }
}
