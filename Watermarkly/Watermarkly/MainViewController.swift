import UIKit
import PhotosUI
import UniformTypeIdentifiers

final class MainViewController: UIViewController, StoreManagerDelegate {

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.appName
        label.font = .systemFont(ofSize: 34, weight: .bold)
        label.textColor = AppTheme.primaryText
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.homeSubtitle
        label.font = .systemFont(ofSize: 17, weight: .regular)
        label.textColor = AppTheme.secondaryText
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var selectButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = L10n.selectPhotos
        config.baseBackgroundColor = AppTheme.accent
        config.baseForegroundColor = .white
        config.cornerStyle = .fixed
        config.background.cornerRadius = AppTheme.cornerRadius
        config.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(selectPhotosTapped), for: .touchUpInside)
        return button
    }()

    private let trialLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = AppTheme.secondaryText
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var featureCardsStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [
            FeaturePreviewCardView(title: L10n.modeTiled, symbolName: "rectangle.grid.2x2"),
            FeaturePreviewCardView(title: L10n.modeCorner, symbolName: "rectangle.inset.filled"),
            FeaturePreviewCardView(title: L10n.modeCard, symbolName: "photo.on.rectangle.angled"),
            FeaturePreviewCardView(title: L10n.modeRetouch, symbolName: "paintbrush.pointed")
        ])
        stack.axis = .horizontal
        stack.spacing = 10
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private var isLoadingPhotos = false
    private var lastWatermarkCanvasSize: CGSize = .zero

    private let backgroundWatermarkView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isUserInteractionEnabled = false
        return imageView
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppTheme.background
        navigationItem.largeTitleDisplayMode = .never
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()
        StoreManager.shared.delegate = self
        setupBackgroundWatermark()
        setupLayout()
        updateUnlockButton()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateBackgroundWatermarkImageIfNeeded()
    }

    private func makeBackgroundWatermarkImage(for imageSize: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: imageSize)
        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            let text = L10n.appName
            let font = UIFont.systemFont(ofSize: 280, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor(white: 0.92, alpha: 0.15)
            ]
            let textSize = (text as NSString).size(withAttributes: attrs)
            let angle: CGFloat = -15.0

            context.saveGState()
            context.translateBy(x: imageSize.width / 2, y: imageSize.height / 2)
            context.rotate(by: angle * .pi / 180)
            (text as NSString).draw(
                at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2),
                withAttributes: attrs
            )
            context.restoreGState()
        }
    }

    private func setupBackgroundWatermark() {
        view.insertSubview(backgroundWatermarkView, at: 0)

        NSLayoutConstraint.activate([
            backgroundWatermarkView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundWatermarkView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundWatermarkView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundWatermarkView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func updateBackgroundWatermarkImageIfNeeded() {
        let canvasSize = view.bounds.size
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        guard canvasSize != lastWatermarkCanvasSize else { return }

        lastWatermarkCanvasSize = canvasSize
        backgroundWatermarkView.image = makeBackgroundWatermarkImage(for: canvasSize)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureTransparentNavigationBar()
        updateTrialLabel()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if navigationController?.topViewController !== self {
            AppTheme.applyNavigationBarAppearance(to: navigationController)
        }
    }

    private func configureTransparentNavigationBar() {
        navigationController?.navigationBar.setBackgroundImage(UIImage(), for: .default)
        navigationController?.navigationBar.shadowImage = UIImage()

        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.shadowColor = .clear
        appearance.backgroundColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: AppTheme.primaryText]

        guard let bar = navigationController?.navigationBar else { return }
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
        bar.tintColor = AppTheme.accent
    }

    func storeManagerDidUpdateUnlockStatus(_ manager: StoreManager) {
        updateTrialLabel()
        updateUnlockButton()
    }

    private func setupLayout() {
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(featureCardsStack)
        view.addSubview(selectButton)
        view.addSubview(trialLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 36),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            featureCardsStack.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 36),
            featureCardsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            featureCardsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            featureCardsStack.heightAnchor.constraint(equalToConstant: 100),

            selectButton.topAnchor.constraint(equalTo: featureCardsStack.bottomAnchor, constant: 36),
            selectButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            trialLabel.topAnchor.constraint(equalTo: selectButton.bottomAnchor, constant: 16),
            trialLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            trialLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }

    private func updateTrialLabel() {
        if TrialManager.shared.isUnlocked {
            trialLabel.text = L10n.unlimitedSavesUnlocked
        } else {
            trialLabel.text = L10n.freeSavesRemaining(TrialManager.shared.remainingTrials)
        }
    }

    private func updateUnlockButton() {
        if TrialManager.shared.isUnlocked {
            navigationItem.rightBarButtonItem = nil
        } else {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: L10n.unlock,
                style: .plain,
                target: self,
                action: #selector(unlockTapped)
            )
        }
    }

    @objc private func unlockTapped() {
        let purchaseVC = PurchaseViewController()
        let nav = UINavigationController(rootViewController: purchaseVC)
        nav.modalPresentationStyle = .formSheet
        purchaseVC.onUnlocked = { [weak self] in
            self?.updateTrialLabel()
            self?.updateUnlockButton()
        }
        present(nav, animated: true)
    }

    @objc private func selectPhotosTapped() {
        guard !isLoadingPhotos else { return }

        var config = PHPickerConfiguration(photoLibrary: .shared())
        let limit = TrialManager.shared.selectionLimit
        config.selectionLimit = limit == 0 ? 0 : limit
        config.filter = .images
        config.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func loadImage(from result: PHPickerResult, index: Int, completion: @escaping (Int, UIImage?) -> Void) {
        let provider = result.itemProvider
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            completion(index, nil)
            return
        }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data else {
                completion(index, nil)
                return
            }
            let image = ImageLoader.image(from: data, maxPixelSize: ImageLimits.pickerMaxPixelSize)
            completion(index, image)
        }
    }
}

private final class FeaturePreviewCardView: UIView {

    private let iconContainer: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1)
        view.layer.cornerRadius = 8
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let iconView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = AppTheme.accent
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = AppTheme.primaryText
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    init(title: String, symbolName: String) {
        super.init(frame: .zero)
        titleLabel.text = title
        iconView.image = UIImage(systemName: symbolName)
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26, weight: .medium)
        setupCardAppearance()
        setupLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupCardAppearance() {
        backgroundColor = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
        layer.cornerRadius = 12
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.08
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 8
    }

    private func setupLayout() {
        addSubview(iconContainer)
        iconContainer.addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconContainer.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            iconContainer.heightAnchor.constraint(equalToConstant: 52),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(lessThanOrEqualTo: iconContainer.widthAnchor, constant: -16),
            iconView.heightAnchor.constraint(lessThanOrEqualTo: iconContainer.heightAnchor, constant: -12),

            titleLabel.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)
        ])
    }
}

extension MainViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }

        isLoadingPhotos = true
        selectButton.isEnabled = false

        let group = DispatchGroup()
        var loaded: [(Int, UIImage)] = []
        let lock = NSLock()

        for (index, result) in results.enumerated() {
            group.enter()
            loadImage(from: result, index: index) { idx, image in
                defer { group.leave() }
                guard let image else { return }
                lock.lock()
                loaded.append((idx, image))
                lock.unlock()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.isLoadingPhotos = false
            self.selectButton.isEnabled = true

            let images = loaded.sorted { $0.0 < $1.0 }.map(\.1)
            guard !images.isEmpty else {
                self.showAlert(title: L10n.unableToLoadPhotos, message: L10n.trySelectingDifferentImages)
                return
            }
            self.navigationController?.pushViewController(EditViewController(images: images), animated: true)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
        present(alert, animated: true)
    }
}
