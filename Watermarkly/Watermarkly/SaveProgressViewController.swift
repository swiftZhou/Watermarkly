import UIKit
import Photos

final class SaveProgressViewController: UIViewController {

    private let totalCount: Int
    private var renderedImages: [UIImage] = []

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.savingPhotos
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let progressView: UIProgressView = {
        let view = UIProgressView(progressViewStyle: .default)
        view.progressTintColor = AppTheme.accent
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    var onComplete: ((Bool, String?) -> Void)?

    init(totalCount: Int) {
        self.totalCount = totalCount
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        let card = UIView()
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = AppTheme.cornerRadius
        card.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(titleLabel)
        card.addSubview(statusLabel)
        card.addSubview(progressView)
        view.addSubview(card)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),

            progressView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
            progressView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            progressView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            progressView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24)
        ])

        statusLabel.text = L10n.preparing
    }

    func updateRenderingProgress(current: Int) {
        let progress = Float(current) / Float(max(totalCount, 1))
        progressView.setProgress(progress * 0.8, animated: true)
        statusLabel.text = L10n.renderingProgress(current: current, total: totalCount)
    }

    func beginSaving() {
        statusLabel.text = L10n.writingToPhotoLibrary
        progressView.setProgress(0.85, animated: true)
    }

    func finishSaving(success: Bool, message: String?) {
        progressView.setProgress(1, animated: true)
        onComplete?(success, message)
    }

    func renderImages(
        sources: [UIImage],
        settings: WatermarkSettings,
        cutoutAppliedIndices: Set<Int> = [],
        retouchStrokePaths: [Int: [[CGPoint]]] = [:],
        completion: @escaping ([UIImage]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var outputs: [UIImage] = []
            outputs.reserveCapacity(sources.count)
            for (index, source) in sources.enumerated() {
                autoreleasepool {
                    let rendered: UIImage
                    if settings.mode == .retouch {
                        let paths = retouchStrokePaths[index] ?? []
                        rendered = WatermarkEngine.applyRetouch(
                            to: source,
                            normalizedStrokePaths: paths,
                            brushDiameter: settings.retouchBrushSize
                        )
                    } else {
                        var working = source
                        if cutoutAppliedIndices.contains(index) {
                            if let cutout = try? WatermarkEngine.removeBackground(from: source) {
                                working = cutout
                            }
                        }
                        if settings.mode == .cutout {
                            rendered = working
                        } else {
                            rendered = WatermarkEngine.applyWatermark(to: working, settings: settings)
                        }
                    }
                    outputs.append(rendered)
                }
                let current = index + 1
                DispatchQueue.main.async {
                    self?.updateRenderingProgress(current: current)
                }
            }
            DispatchQueue.main.async {
                completion(outputs)
            }
        }
    }

    func updateCutoutProgress(current: Int, total: Int) {
        let progress = Float(current) / Float(max(total, 1))
        progressView.setProgress(progress * 0.4, animated: true)
        statusLabel.text = L10n.cutoutProgress(current: current, total: total)
    }

    func saveToLibrary(_ images: [UIImage], consumeTrialIfNeeded: Bool) {
        beginSaving()
        if consumeTrialIfNeeded {
            TrialManager.shared.consumeTrial()
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized || status == .limited else {
                    self.finishSaving(
                        success: false,
                        message: L10n.allowPhotoLibraryAccess
                    )
                    return
                }
                self.saveNextImage(from: images, index: 0)
            }
        }
    }

    private func saveNextImage(from images: [UIImage], index: Int) {
        guard index < images.count else {
            finishSaving(
                success: true,
                message: L10n.photosSaved(images.count)
            )
            return
        }

        let exportImage = ImageLoader.flattenForExport(images[index])
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: exportImage)
        }) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    let progress = 0.85 + (Float(index + 1) / Float(max(images.count, 1))) * 0.15
                    self.progressView.setProgress(progress, animated: true)
                    self.saveNextImage(from: images, index: index + 1)
                } else {
                    self.finishSaving(
                        success: false,
                        message: error?.localizedDescription ?? L10n.unableToSavePhotos
                    )
                }
            }
        }
    }
}
