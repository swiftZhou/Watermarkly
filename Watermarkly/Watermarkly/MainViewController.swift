import UIKit
import PhotosUI
import UniformTypeIdentifiers
import SafariServices

final class MainViewController: UIViewController, StoreManagerDelegate {

    private let scrollView: UIScrollView = {
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()

    private let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.appName
        label.font = .systemFont(ofSize: 34, weight: .bold)
        label.textColor = AppTheme.primaryText
        label.textAlignment = .center
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.homeSubtitle
        label.font = .systemFont(ofSize: 16, weight: .regular)
        label.textColor = AppTheme.secondaryText
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private lazy var featureCardsStack: UIStackView = {
        let cards = [
            FeaturePreviewCardView(
                title: L10n.modeTiled,
                subtitle: L10n.homeTiledSubtitle,
                symbolName: "rectangle.grid.2x2",
                action: .watermark(.tiled)
            ),
            FeaturePreviewCardView(
                title: L10n.modeCorner,
                subtitle: L10n.homeCornerSubtitle,
                symbolName: "rectangle.inset.filled",
                action: .watermark(.corner)
            ),
            FeaturePreviewCardView(
                title: L10n.modeCard,
                subtitle: L10n.homeCardSubtitle,
                symbolName: "photo.on.rectangle.angled",
                action: .watermark(.card)
            ),
            FeaturePreviewCardView(
                title: L10n.modeRetouch,
                subtitle: L10n.homeRetouchSubtitle,
                symbolName: "paintbrush.pointed",
                action: .watermark(.retouch)
            ),
            FeaturePreviewCardView(
                title: L10n.collageTitle,
                subtitle: L10n.homeCollageSubtitle,
                symbolName: "square.grid.3x3",
                action: .collage
            ),
            FeaturePreviewCardView(
                title: L10n.homeCutoutTitle,
                subtitle: L10n.homeCutoutSubtitle,
                symbolName: "person.crop.rectangle",
                action: .watermark(.cutout)
            )
        ]
        let stack = UIStackView(arrangedSubviews: cards)
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        return stack
    }()

    private let trialLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = AppTheme.secondaryText
        label.textAlignment = .center
        return label
    }()

    private lazy var privacyPolicyButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = L10n.privacyPolicy
        config.baseForegroundColor = AppTheme.secondaryText
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        var title = AttributedString(L10n.privacyPolicy)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.underlineStyle = .single
        config.attributedTitle = title
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(privacyPolicyTapped), for: .touchUpInside)
        return button
    }()

    private var isLoadingPhotos = false
    private var pendingLaunchAction: HomeLaunchAction = .watermark(.tiled)
    private var lastWatermarkCanvasSize: CGSize = .zero
    private var contentTopConstraint: NSLayoutConstraint?

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
        updateContentTopInset()
    }

    private func updateContentTopInset() {
        let top = view.safeAreaInsets.top
        guard contentTopConstraint?.constant != top else { return }
        contentTopConstraint?.constant = top
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        PrivacyConsent.presentIfNeeded(from: self)
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
        let header = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        header.axis = .vertical
        header.spacing = 8
        header.alignment = .fill

        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(featureCardsStack)
        contentStack.addArrangedSubview(trialLabel)
        contentStack.addArrangedSubview(privacyPolicyButton)
        contentStack.setCustomSpacing(28, after: header)
        contentStack.setCustomSpacing(28, after: featureCardsStack)
        contentStack.setCustomSpacing(20, after: trialLabel)

        for case let card as FeaturePreviewCardView in featureCardsStack.arrangedSubviews {
            card.addTarget(self, action: #selector(featureCardTapped(_:)), for: .touchUpInside)
        }

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        let topConstraint = contentStack.topAnchor.constraint(
            equalTo: scrollView.contentLayoutGuide.topAnchor,
            constant: 12
        )
        contentTopConstraint = topConstraint

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            topConstraint,
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24)
        ])
        updateContentTopInset()
    }

    @objc private func privacyPolicyTapped() {
        let safari = SFSafariViewController(url: AppLinks.privacyPolicy)
        safari.preferredControlTintColor = AppTheme.accent
        present(safari, animated: true)
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
        guard PrivacyConsent.hasAgreed else {
            PrivacyConsent.presentIfNeeded(from: self)
            return
        }
        let purchaseVC = PurchaseViewController()
        let nav = UINavigationController(rootViewController: purchaseVC)
        nav.modalPresentationStyle = .formSheet
        purchaseVC.onUnlocked = { [weak self] in
            self?.updateTrialLabel()
            self?.updateUnlockButton()
        }
        present(nav, animated: true)
    }

    @objc private func featureCardTapped(_ sender: FeaturePreviewCardView) {
        pendingLaunchAction = sender.action
        presentPhotoPicker()
    }

    private func presentPhotoPicker() {
        guard PrivacyConsent.hasAgreed else {
            PrivacyConsent.presentIfNeeded(from: self)
            return
        }
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

    private func openEditor(with images: [UIImage]) {
        let editVC: EditViewController
        switch pendingLaunchAction {
        case .watermark(let mode):
            editVC = EditViewController(images: images, initialMode: mode)
        case .collage:
            editVC = EditViewController(images: images, initialMode: .cutout, opensCollageOnAppear: true)
        }
        navigationController?.pushViewController(editVC, animated: true)
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

// MARK: - Home launch

private enum HomeLaunchAction {
    case watermark(WatermarkMode)
    case collage
}

// MARK: - Feature cards

private final class FeaturePreviewCardView: UIControl {

    let action: HomeLaunchAction

    private let iconContainer: UIView = {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = AppTheme.accent.withAlphaComponent(0.08)
        view.layer.cornerRadius = 12
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
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = AppTheme.primaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = AppTheme.secondaryText
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let chevronView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "chevron.right"))
        imageView.tintColor = AppTheme.secondaryText.withAlphaComponent(0.55)
        imageView.contentMode = .scaleAspectFit
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.85 : 1 }
    }

    init(title: String, subtitle: String, symbolName: String, action: HomeLaunchAction) {
        self.action = action
        super.init(frame: .zero)
        titleLabel.text = title
        subtitleLabel.text = subtitle
        iconView.image = UIImage(systemName: symbolName)
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)

        backgroundColor = .white
        layer.cornerRadius = 14
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.06
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 6

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.alignment = .fill
        textStack.isUserInteractionEnabled = false
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconContainer)
        iconContainer.addSubview(iconView)
        addSubview(textStack)
        addSubview(chevronView)

        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 48),
            iconContainer.heightAnchor.constraint(equalToConstant: 48),
            iconContainer.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 14),
            iconContainer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -14),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),

            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 10),

            textStack.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -10),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension MainViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }

        isLoadingPhotos = true

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

            let images = loaded.sorted { $0.0 < $1.0 }.map(\.1)
            guard !images.isEmpty else {
                self.showAlert(title: L10n.unableToLoadPhotos, message: L10n.trySelectingDifferentImages)
                return
            }
            self.openEditor(with: images)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
        present(alert, animated: true)
    }
}
