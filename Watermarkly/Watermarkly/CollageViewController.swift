import UIKit
import Photos

final class CollageViewController: UIViewController {

    private let sourcePreviewImages: [UIImage]
    private let onExport: (CollageLayoutOptions, [Int], @escaping (UIImage?) -> Void) -> Void

    private var orderedImages: [UIImage]
    private var imagePermutation: [Int]
    private var options = CollageLayoutOptions()
    private var exportInFlight = false

    private let scrollView: CollageOptionsScrollView = {
        let scroll = CollageOptionsScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()

    private let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private lazy var layoutControl: UISegmentedControl = {
        let control = UISegmentedControl(items: CollageLayoutType.allCases.map(\.title))
        control.selectedSegmentIndex = 0
        control.addTarget(self, action: #selector(optionsChanged), for: .valueChanged)
        return control
    }()

    private lazy var backgroundControl: UISegmentedControl = {
        let control = UISegmentedControl(items: CollageBackgroundStyle.allCases.map(\.title))
        control.selectedSegmentIndex = 0
        control.addTarget(self, action: #selector(optionsChanged), for: .valueChanged)
        return control
    }()

    private lazy var spacingRow = SliderRowView(
        title: L10n.spacing,
        min: 0,
        max: 80,
        value: Float(CollageLayoutType.grid3x3.baseSpacing)
    ) { value in String(format: "%.0f pt", value) }

    private lazy var heroSwitch: UISwitch = {
        let toggle = UISwitch()
        toggle.isOn = false
        toggle.addTarget(self, action: #selector(optionsChanged), for: .valueChanged)
        return toggle
    }()

    private lazy var heroRow: UIStackView = {
        let label = UILabel()
        label.text = L10n.collageHeroLayout
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = AppTheme.primaryText
        let stack = UIStackView(arrangedSubviews: [label, heroSwitch])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .equalSpacing
        return stack
    }()

    private let hintLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.collageInteractionHint
        label.font = .systemFont(ofSize: 13)
        label.textColor = AppTheme.secondaryText
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }()

    private let collagePreview: CollageInteractivePreviewView = {
        let view = CollageInteractivePreviewView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var thumbnailCollection: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 8
        layout.itemSize = CGSize(width: 64, height: 64)
        let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.showsHorizontalScrollIndicator = false
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.register(CollageThumbnailCell.self, forCellWithReuseIdentifier: CollageThumbnailCell.reuseID)
        collection.dataSource = self
        collection.dragDelegate = self
        collection.dropDelegate = self
        collection.dragInteractionEnabled = true
        return collection
    }()

    private lazy var saveButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = L10n.saveCollage
        config.baseBackgroundColor = AppTheme.accent
        config.baseForegroundColor = .white
        config.cornerStyle = .fixed
        config.background.cornerRadius = AppTheme.cornerRadius
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        return button
    }()

    private lazy var shareButton: UIButton = {
        var config = UIButton.Configuration.bordered()
        config.title = L10n.shareCollage
        config.baseForegroundColor = AppTheme.accent
        config.cornerStyle = .fixed
        config.background.cornerRadius = AppTheme.cornerRadius
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        return button
    }()

    private lazy var actionBar: UIView = {
        let bar = UIView()
        bar.backgroundColor = AppTheme.background
        bar.translatesAutoresizingMaskIntoConstraints = false

        let topLine = UIView()
        topLine.backgroundColor = AppTheme.fieldBorder
        topLine.translatesAutoresizingMaskIntoConstraints = false

        let row = UIStackView(arrangedSubviews: [saveButton, shareButton])
        row.axis = .horizontal
        row.spacing = 12
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(topLine)
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: bar.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            row.topAnchor.constraint(equalTo: bar.topAnchor, constant: 12),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -20),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -12)
        ])
        return bar
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    private var previewHeightConstraint: NSLayoutConstraint?

    init(
        previewImages: [UIImage],
        onExport: @escaping (CollageLayoutOptions, [Int], @escaping (UIImage?) -> Void) -> Void
    ) {
        self.sourcePreviewImages = previewImages
        self.orderedImages = previewImages
        self.imagePermutation = Array(0..<previewImages.count)
        self.onExport = onExport
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppTheme.background

        navigationItem.title = L10n.collageTitle
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )

        collagePreview.delegate = self

        view.addSubview(scrollView)
        view.addSubview(actionBar)
        scrollView.addSubview(contentStack)
        scrollView.keyboardDismissMode = .onDrag
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true

        contentStack.addArrangedSubview(sectionLabel(L10n.collageLayoutSection))
        contentStack.addArrangedSubview(layoutControl)
        contentStack.addArrangedSubview(sectionLabel(L10n.collageBackgroundSection))
        contentStack.addArrangedSubview(backgroundControl)
        contentStack.addArrangedSubview(heroRow)
        contentStack.addArrangedSubview(spacingRow)
        contentStack.addArrangedSubview(hintLabel)
        contentStack.addArrangedSubview(collagePreview)
        contentStack.addArrangedSubview(thumbnailCollection)

        spacingRow.onValueChanged = { [weak self] value in
            self?.options.spacing = CGFloat(value)
            self?.refreshPreviewLayout()
        }
        spacingRow.onEditingEnded = { [weak self] in
            guard let self else { return }
            self.options.spacing = CGFloat(self.spacingRow.slider.value)
            self.refreshPreviewLayout()
        }

        previewHeightConstraint = collagePreview.heightAnchor.constraint(equalTo: collagePreview.widthAnchor, multiplier: 1)

        NSLayoutConstraint.activate([
            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: actionBar.topAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),

            thumbnailCollection.heightAnchor.constraint(equalToConstant: 72),
            previewHeightConstraint!
        ])

        view.addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: collagePreview.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: collagePreview.centerYAnchor)
        ])

        syncControlsFromOptions()
        refreshPreviewLayout()
        thumbnailCollection.reloadData()
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = AppTheme.secondaryText
        return label
    }

    private func syncControlsFromOptions() {
        layoutControl.selectedSegmentIndex = options.layoutType.rawValue
        backgroundControl.selectedSegmentIndex = options.backgroundStyle.rawValue
        heroSwitch.isOn = options.heroLayout
        spacingRow.setValue(Float(options.spacing))

        heroRow.isHidden = !options.layoutType.supportsHeroLayout

        let aspect = options.layoutType.canvasSize.height / max(options.layoutType.canvasSize.width, 1)
        previewHeightConstraint?.isActive = false
        previewHeightConstraint = collagePreview.heightAnchor.constraint(
            equalTo: collagePreview.widthAnchor,
            multiplier: aspect
        )
        previewHeightConstraint?.isActive = true
    }

    private func syncOptionsFromControls() {
        options.layoutType = CollageLayoutType(rawValue: layoutControl.selectedSegmentIndex) ?? .grid3x3
        options.backgroundStyle = CollageBackgroundStyle(rawValue: backgroundControl.selectedSegmentIndex) ?? .white
        options.heroLayout = heroSwitch.isOn
        options.spacing = CGFloat(spacingRow.slider.value)

        switch options.backgroundStyle {
        case .white:
            options.cellPadColor = .white
        case .lightGray:
            options.cellPadColor = UIColor(white: 0.94, alpha: 1)
        case .blurred:
            options.cellPadColor = .white
        }
    }

    private func refreshPreviewLayout() {
        collagePreview.configure(images: orderedImages, options: options)
    }

    private func swapImages(at a: Int, with b: Int) {
        guard a != b, a >= 0, b >= 0, a < orderedImages.count, b < orderedImages.count else { return }
        orderedImages.swapAt(a, b)
        imagePermutation.swapAt(a, b)

        var adjustments = options.cellAdjustments
        let adjA = adjustments[a] ?? CollageCellAdjustment()
        let adjB = adjustments[b] ?? CollageCellAdjustment()
        adjustments[a] = adjB
        adjustments[b] = adjA
        options.cellAdjustments = adjustments

        refreshPreviewLayout()
        thumbnailCollection.reloadData()
    }

    private func removeImage(at index: Int) {
        guard orderedImages.indices.contains(index) else { return }
        guard orderedImages.count > 1 else {
            presentAlert(title: L10n.collageTitle, message: L10n.collageNeedOnePhoto)
            return
        }

        orderedImages.remove(at: index)
        imagePermutation.remove(at: index)

        var remapped: [Int: CollageCellAdjustment] = [:]
        for (slot, adjustment) in options.cellAdjustments {
            if slot < index {
                remapped[slot] = adjustment
            } else if slot > index {
                remapped[slot - 1] = adjustment
            }
        }
        options.cellAdjustments = remapped

        refreshPreviewLayout()
        thumbnailCollection.reloadData()
    }

    @objc private func optionsChanged() {
        let keptSpacing = CGFloat(spacingRow.slider.value)
        syncOptionsFromControls()
        options.spacing = keptSpacing
        options.cellAdjustments = [:]
        syncControlsFromOptions()
        refreshPreviewLayout()
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        exportCollage { [weak self] image in
            guard let self, let image else {
                self?.presentAlert(title: L10n.saveFailed, message: L10n.collageExportFailed)
                return
            }
            self.saveToPhotos(image)
        }
    }

    @objc private func shareTapped() {
        exportCollage { [weak self] image in
            guard let self, let image else {
                self?.presentAlert(title: L10n.saveFailed, message: L10n.collageExportFailed)
                return
            }
            let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.sourceView = self.shareButton
                popover.sourceRect = self.shareButton.bounds
            }
            self.present(activity, animated: true)
        }
    }

    private func exportCollage(completion: @escaping (UIImage?) -> Void) {
        guard !exportInFlight else { return }
        exportInFlight = true
        setLoading(true)
        syncOptionsFromControls()
        options.cellAdjustments = collagePreview.currentAdjustments()

        onExport(options, imagePermutation) { [weak self] image in
            DispatchQueue.main.async {
                self?.exportInFlight = false
                self?.setLoading(false)
                completion(image)
            }
        }
    }

    private func setLoading(_ loading: Bool) {
        saveButton.isEnabled = !loading
        shareButton.isEnabled = !loading
        layoutControl.isEnabled = !loading
        backgroundControl.isEnabled = !loading
        heroSwitch.isEnabled = !loading
        spacingRow.slider.isEnabled = !loading
        thumbnailCollection.isUserInteractionEnabled = !loading
        loading ? activityIndicator.startAnimating() : activityIndicator.stopAnimating()
    }

    private func saveToPhotos(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized || status == .limited else {
                    self.presentAlert(title: L10n.saveFailed, message: L10n.allowPhotoLibraryAccess)
                    return
                }
                let exportImage = ImageLoader.flattenForExport(image)
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: exportImage)
                }) { success, error in
                    DispatchQueue.main.async {
                        if success {
                            self.presentAlert(title: L10n.saved, message: L10n.collageSaved)
                        } else {
                            self.presentAlert(
                                title: L10n.saveFailed,
                                message: error?.localizedDescription ?? L10n.unableToSavePhotos
                            )
                        }
                    }
                }
            }
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
        present(alert, animated: true)
    }
}

/// Keeps UISlider interaction from being cancelled by the options UIScrollView.
private final class CollageOptionsScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UISlider || view.superview is UISlider {
            return false
        }
        return super.touchesShouldCancel(in: view)
    }
}

// MARK: - Preview delegate

extension CollageViewController: CollageInteractivePreviewViewDelegate {
    func collagePreview(_ preview: CollageInteractivePreviewView, didSwapSlot from: Int, with to: Int) {
        swapImages(at: from, with: to)
    }

    func collagePreview(_ preview: CollageInteractivePreviewView, didUpdateAdjustment adjustment: CollageCellAdjustment, forSlot slotIndex: Int) {
        options.cellAdjustments[slotIndex] = adjustment
    }

    func collagePreviewSelectionDidChange(_ preview: CollageInteractivePreviewView) {
        // No-op; selection drives pan/pinch inside the cell.
    }
}

// MARK: - Thumbnails

private final class CollageThumbnailCell: UICollectionViewCell {
    static let reuseID = "CollageThumbnailCell"

    var onDelete: (() -> Void)?

    private let imageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 8
        view.layer.borderWidth = 1
        view.layer.borderColor = AppTheme.fieldBorder.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var deleteButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "minus.circle.fill")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.tintColor = .systemRed
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = L10n.collageRemovePhoto
        button.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(imageView)
        contentView.addSubview(deleteButton)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            deleteButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            deleteButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
            deleteButton.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onDelete = nil
        imageView.image = nil
    }

    func configure(image: UIImage, onDelete: @escaping () -> Void) {
        imageView.image = image
        self.onDelete = onDelete
    }

    @objc private func deleteTapped() {
        onDelete?()
    }
}

extension CollageViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        orderedImages.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: CollageThumbnailCell.reuseID,
            for: indexPath
        ) as! CollageThumbnailCell
        cell.configure(image: orderedImages[indexPath.item]) { [weak self, weak cell] in
            guard let self, let cell,
                  let current = self.thumbnailCollection.indexPath(for: cell) else { return }
            self.removeImage(at: current.item)
        }
        return cell
    }
}

extension CollageViewController: UICollectionViewDragDelegate, UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        let provider = NSItemProvider(object: NSString(string: "\(indexPath.item)"))
        let item = UIDragItem(itemProvider: provider)
        item.localObject = indexPath.item
        return [item]
    }

    func collectionView(_ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UICollectionViewDropProposal {
        UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let destinationIndexPath = coordinator.destinationIndexPath,
              let item = coordinator.items.first,
              let sourceIndexPath = item.sourceIndexPath else { return }

        if sourceIndexPath.item != destinationIndexPath.item {
            swapImages(at: sourceIndexPath.item, with: destinationIndexPath.item)
        }
        coordinator.drop(item.dragItem, toItemAt: destinationIndexPath)
    }
}
