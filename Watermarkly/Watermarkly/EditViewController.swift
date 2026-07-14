import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers

final class EditViewController: UIViewController {

    private let images: [UIImage]
    private var settings = WatermarkSettings()
    private var currentIndex = 0
    private var previewTask: DispatchWorkItem?
    private var overlayRenderInFlight = false
    private var overlayRenderQueued = false
    private var cachedSpacingPreviewSource: UIImage?
    private var cachedSpacingPreviewBase: UIImage?
    private var cachedSpacingPreviewIndex: Int?
    private var committedOpacity: CGFloat = 0.4
    private var committedRotation: CGFloat = -45
    private var committedScale: CGFloat = 1.0
    private var committedSpacing: CGFloat = 50
    private var savedInteractivePopEnabled = true
    private var savedInteractiveContentPopEnabled = true

    private enum CachedPreview {
        case flat(UIImage)
        case layered(base: UIImage, overlay: UIImage)
    }

    private var previewCache: [Int: CachedPreview] = [:]
    private var baseImageCache: [Int: UIImage] = [:]
    private var previewPreloadGeneration = 0
    private var retouchCompositeCache: [Int: UIImage] = [:]
    private var retouchMaskCache: [Int: UIImage] = [:]
    private var retouchActiveStroke: [Int: [CGPoint]] = [:]
    /// One array per committed finger stroke (normalized image points).
    private var retouchNormalizedStrokePaths: [Int: [[CGPoint]]] = [:]
    /// Snapshots before each committed stroke (`nil` = original base image).
    private var retouchUndoSnapshots: [Int: [UIImage?]] = [:]
    private var retouchCommitGeneration: [Int: Int] = [:]
    private static let maxRetouchUndosPerPhoto = 20
    private let retouchQuickQueue = DispatchQueue(label: "com.watermarkly.retouch.quick", qos: .userInteractive)

    private static let retouchBrushColors: [UIColor] = [
        UIColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1),
        UIColor(red: 1.0, green: 0.58, blue: 0, alpha: 1),
        UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1),
        UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        AppTheme.accent,
        UIColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)
    ]
    private var retouchColorButtons: [UIButton] = []

    // MARK: - Preview

    private let previewContainer: UIView = {
        let view = UIView()
        view.backgroundColor = AppTheme.background
        view.layer.cornerRadius = AppTheme.cornerRadius
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.08
        view.layer.shadowRadius = 8
        view.layer.shadowOffset = CGSize(width: 0, height: 2)
        view.isMultipleTouchEnabled = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let photoPager = EditPhotoPagerView()

    private let previewSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        return spinner
    }()

    private let pageLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = AppTheme.secondaryText
        label.textAlignment = .center
        return label
    }()

    private lazy var previousPhotoButton: UIButton = {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .fixed
        config.background.cornerRadius = AppTheme.cornerRadius
        config.title = L10n.previous
        config.image = UIImage(systemName: "chevron.left")
        config.imagePadding = 6
        config.baseForegroundColor = AppTheme.primaryText
        let button = UIButton(configuration: config)
        button.addTarget(self, action: #selector(previousPhotoTapped), for: .touchUpInside)
        return button
    }()

    private lazy var nextPhotoButton: UIButton = {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .fixed
        config.background.cornerRadius = AppTheme.cornerRadius
        config.title = L10n.next
        config.image = UIImage(systemName: "chevron.right")
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.baseForegroundColor = AppTheme.primaryText
        let button = UIButton(configuration: config)
        button.addTarget(self, action: #selector(nextPhotoTapped), for: .touchUpInside)
        return button
    }()

    private lazy var photoNavStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [previousPhotoButton, nextPhotoButton])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.distribution = .fillEqually
        stack.isHidden = true
        return stack
    }()

    private lazy var pageChromeStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [photoNavStack, pageLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private lazy var saveAllBarButton = UIBarButtonItem(
        title: L10n.saveAll,
        style: .done,
        target: self,
        action: #selector(saveAllTapped)
    )

    private lazy var undoRetouchBarButton: UIBarButtonItem = {
        let item = UIBarButtonItem(
            title: L10n.undo,
            style: .plain,
            target: self,
            action: #selector(undoRetouchTapped)
        )
        item.isEnabled = false
        return item
    }()

    // MARK: - Controls scroll area

    private let controlsScrollView: ControlsScrollView = {
        let scroll = ControlsScrollView()
        scroll.alwaysBounceVertical = true
        scroll.delaysContentTouches = false
        scroll.canCancelContentTouches = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()

    private let controlsStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private lazy var modeControl: UISegmentedControl = {
        let control = UISegmentedControl(items: WatermarkMode.allCases.map(\.title))
        control.selectedSegmentIndex = 0
        control.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        return control
    }()

    private let textField: UITextField = {
        let field = UITextField()
        field.placeholder = L10n.watermarkTextPlaceholder
        field.borderStyle = .none
        field.font = .systemFont(ofSize: 16)
        field.textColor = AppTheme.primaryText
        field.backgroundColor = AppTheme.fieldBackground
        field.layer.cornerRadius = AppTheme.cornerRadius
        field.layer.borderWidth = 1
        field.layer.borderColor = AppTheme.fieldBorder.cgColor
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.rightViewMode = .always
        return field
    }()

    private lazy var logoButton: UIButton = {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .fixed
        config.background.cornerRadius = AppTheme.cornerRadius
        config.title = L10n.chooseLogo
        config.image = UIImage(systemName: "photo")
        config.imagePadding = 8
        let button = UIButton(configuration: config)
        button.addTarget(self, action: #selector(chooseLogoTapped), for: .touchUpInside)
        return button
    }()

    private lazy var clearLogoButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = L10n.clearLogo
        config.baseForegroundColor = .systemRed
        let button = UIButton(configuration: config)
        button.isHidden = true
        button.addTarget(self, action: #selector(clearLogoTapped), for: .touchUpInside)
        return button
    }()

    private lazy var opacityRow = SliderRowView(
        title: L10n.opacity, min: 0.1, max: 1.0, value: 0.4
    ) { value in String(format: "%.0f%%", value * 100) }

    private lazy var rotationRow = SliderRowView(
        title: L10n.rotation, min: -90, max: 90, value: -45
    ) { value in String(format: "%.0f°", value) }

    private lazy var spacingRow = SliderRowView(
        title: L10n.spacing, min: 10, max: 120, value: 50
    ) { value in String(format: "%.0f pt", value) }

    private lazy var sizeRow = SliderRowView(
        title: L10n.size, min: 0.5, max: 2.5, value: 1.0
    ) { value in String(format: "%.0f%%", value * 100) }

    private lazy var borderWidthRow = SliderRowView(
        title: L10n.borderWidth, min: 2, max: 18, value: 8
    ) { value in String(format: "%.0f%%", value) }

    /// Brush Size UI is 0%…100% → diameter 50…200 pt.
    private static let retouchBrushDiameterAtZeroPercent: CGFloat = 50
    private static let retouchBrushDiameterAtFullPercent: CGFloat = 200

    private lazy var brushSizeRow = SliderRowView(
        title: L10n.brushSize, min: 0, max: 100, value: 0
    ) { value in String(format: "%.0f%%", value) }

    private let retouchColorHeaderLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.brushColor
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = AppTheme.primaryText
        label.isHidden = true
        return label
    }()

    private let retouchColorContainer: UIView = {
        let view = UIView()
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var retouchColorStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private lazy var frameCaptionSwitch: UISwitch = {
        let toggle = UISwitch()
        toggle.isOn = true
        toggle.addTarget(self, action: #selector(frameCaptionToggled), for: .valueChanged)
        return toggle
    }()

    private lazy var frameCaptionRow: UIStackView = {
        let label = UILabel()
        label.text = L10n.showCaption
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = AppTheme.primaryText

        let stack = UIStackView(arrangedSubviews: [label, frameCaptionSwitch])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isHidden = true
        return stack
    }()

    private lazy var cornerPositionControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [
            L10n.cornerTL, L10n.cornerTR, L10n.cornerBL, L10n.cornerBR, L10n.cornerC
        ])
        control.selectedSegmentIndex = CornerPosition.bottomRight.rawValue
        control.addTarget(self, action: #selector(cornerPositionChanged), for: .valueChanged)
        return control
    }()

    private lazy var templateCollectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 100, height: 120)
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)

        let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.showsHorizontalScrollIndicator = false
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.register(DeviceFrameTemplateCell.self, forCellWithReuseIdentifier: DeviceFrameTemplateCell.reuseID)
        collection.dataSource = self
        collection.delegate = self
        collection.heightAnchor.constraint(equalToConstant: 128).isActive = true
        return collection
    }()

    private let templateHeaderLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.deviceTemplate
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = AppTheme.primaryText
        return label
    }()

    private let cornerHeaderLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.position
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = AppTheme.primaryText
        return label
    }()

    // MARK: - Init

    init(images: [UIImage]) {
        self.images = images
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.edit
        view.backgroundColor = AppTheme.background
        navigationController?.navigationBar.tintColor = AppTheme.accent
        navigationItem.rightBarButtonItems = [saveAllBarButton]

        textField.text = settings.text
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)

        setupLayout()
        photoPager.dataSource = self
        photoPager.delegate = self
        photoPager.configure(imageCount: images.count, initialPage: currentIndex)
        photoPager.layoutIfNeeded()
        bindSliders()
        bindFrameSliders()
        updateModeControls()
        updateLogoControls()
        updatePageLabel()
        preloadBaseImages()
        refreshPreview(invalidateCache: true)
        updateRetouchInteraction()

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        disableNavigationSwipeBack()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        disableNavigationSwipeBack()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent else { return }
        restoreNavigationSwipeBack()
    }

    // MARK: - Layout

    private func setupLayout() {
        photoPager.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(previewContainer)
        previewContainer.addSubview(photoPager)
        previewContainer.addSubview(previewSpinner)
        view.addSubview(pageChromeStack)
        view.addSubview(controlsScrollView)
        controlsScrollView.addSubview(controlsStack)

        controlsStack.addArrangedSubview(modeControl)
        controlsStack.addArrangedSubview(textField)
        controlsStack.addArrangedSubview(frameCaptionRow)
        controlsStack.addArrangedSubview(logoButton)
        controlsStack.addArrangedSubview(clearLogoButton)
        controlsStack.addArrangedSubview(opacityRow)
        controlsStack.addArrangedSubview(rotationRow)
        controlsStack.addArrangedSubview(spacingRow)
        controlsStack.addArrangedSubview(sizeRow)
        controlsStack.addArrangedSubview(borderWidthRow)
        controlsStack.addArrangedSubview(brushSizeRow)
        controlsStack.addArrangedSubview(retouchColorHeaderLabel)
        controlsStack.addArrangedSubview(retouchColorContainer)
        retouchColorContainer.addSubview(retouchColorStack)
        NSLayoutConstraint.activate([
            retouchColorStack.topAnchor.constraint(equalTo: retouchColorContainer.topAnchor),
            retouchColorStack.bottomAnchor.constraint(equalTo: retouchColorContainer.bottomAnchor),
            retouchColorStack.centerXAnchor.constraint(equalTo: retouchColorContainer.centerXAnchor)
        ])
        setupRetouchColorPicker()
        controlsStack.addArrangedSubview(cornerHeaderLabel)
        controlsStack.addArrangedSubview(cornerPositionControl)
        controlsStack.addArrangedSubview(templateHeaderLabel)
        controlsStack.addArrangedSubview(templateCollectionView)

        textField.heightAnchor.constraint(equalToConstant: 44).isActive = true

        NSLayoutConstraint.activate([
            previewContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            previewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            previewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            previewContainer.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.38),

            photoPager.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 8),
            photoPager.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 8),
            photoPager.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -8),
            photoPager.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -8),

            previewSpinner.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            previewSpinner.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),

            pageChromeStack.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 6),
            pageChromeStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            pageChromeStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            previousPhotoButton.heightAnchor.constraint(equalToConstant: 36),
            nextPhotoButton.heightAnchor.constraint(equalToConstant: 36),

            controlsScrollView.topAnchor.constraint(equalTo: pageChromeStack.bottomAnchor, constant: 8),
            controlsScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlsScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlsScrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            controlsStack.topAnchor.constraint(equalTo: controlsScrollView.contentLayoutGuide.topAnchor, constant: 8),
            controlsStack.leadingAnchor.constraint(equalTo: controlsScrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            controlsStack.trailingAnchor.constraint(equalTo: controlsScrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            controlsStack.bottomAnchor.constraint(equalTo: controlsScrollView.contentLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    private func currentPreviewView() -> ZoomableImageView? {
        photoPager.visiblePreviewView()
    }

    private func bindSliders() {
        opacityRow.onValueChanged = { [weak self] _ in self?.updateLiveWatermarkPreview() }
        opacityRow.onEditingEnded = { [weak self] in
            self?.commitSliderValues()
            self?.refreshPreview(invalidateCache: true, showSpinner: false)
        }

        rotationRow.onValueChanged = { [weak self] _ in self?.scheduleOverlayRefresh() }
        rotationRow.onEditingEnded = { [weak self] in
            guard let self else { return }
            self.commitSliderValues()
            self.syncCommittedPreviewValues()
        }

        sizeRow.onValueChanged = { [weak self] _ in
            guard let self else { return }
            if self.settings.mode == .corner {
                self.scheduleOverlayRefresh()
            } else {
                self.updateLiveWatermarkPreview()
            }
        }
        sizeRow.onEditingEnded = { [weak self] in
            guard let self else { return }
            self.commitSliderValues()
            if self.settings.mode == .corner {
                self.syncCommittedPreviewValues()
            } else {
                self.refreshPreview(invalidateCache: true, showSpinner: false)
            }
        }

        spacingRow.onValueChanged = { [weak self] _ in self?.scheduleOverlayRefresh() }
        spacingRow.onEditingEnded = { [weak self] in
            guard let self else { return }
            self.commitSliderValues()
            self.syncCommittedPreviewValues()
        }
    }

    private func bindFrameSliders() {
        let refreshFramePreview = { [weak self] in
            self?.refreshPreview(invalidateCache: true, showSpinner: false)
        }
        borderWidthRow.onValueChanged = { _ in refreshFramePreview() }
        borderWidthRow.onEditingEnded = { [weak self] in
            self?.commitSliderValues()
            refreshFramePreview()
        }
        brushSizeRow.onEditingBegan = { [weak self] in
            self?.showBrushSizeIndicator()
        }
        brushSizeRow.onValueChanged = { [weak self] _ in
            guard let self else { return }
            self.settings.retouchBrushSize = self.brushDiameter(fromPercent: self.brushSizeRow.slider.value)
            // Only while dragging — valueChanged can fire again after touch-up and would re-show the indicator.
            if self.brushSizeRow.slider.isTracking {
                self.showBrushSizeIndicator()
            }
        }
        brushSizeRow.onEditingEnded = { [weak self] in
            guard let self else { return }
            self.settings.retouchBrushSize = self.brushDiameter(fromPercent: self.brushSizeRow.slider.value)
            self.commitSliderValues()
            self.hideBrushSizeIndicator()
        }
    }

    // MARK: - Actions

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    @objc private func modeChanged() {
        settings.mode = WatermarkMode(rawValue: modeControl.selectedSegmentIndex) ?? .tiled
        updateModeControls()
        updateLogoControls()
        updateRetouchInteraction()
        updatePageLabel()
        if settings.mode == .retouch {
            refreshRetouchPreview(at: currentIndex)
        } else {
            resetVisiblePreviewsToBase()
            refreshPreview(invalidateCache: true)
        }
    }

    private func resetVisiblePreviewsToBase() {
        for index in 0..<images.count {
            guard let cell = photoPager.cell(at: index) else { continue }
            cell.prepareForPhoto(at: index)
            if let base = baseImageCache[index] {
                cell.zoomablePreview.image = base
            } else {
                cell.zoomablePreview.image = nil
            }
        }
    }

    @objc private func cornerPositionChanged() {
        settings.cornerPosition = CornerPosition(rawValue: cornerPositionControl.selectedSegmentIndex) ?? .bottomRight
        refreshPreview(invalidateCache: true)
    }

    @objc private func textChanged() {
        settings.text = textField.text ?? ""
        refreshPreview(invalidateCache: true)
    }

    @objc private func frameCaptionToggled() {
        settings.frameShowsCaption = frameCaptionSwitch.isOn
        refreshPreview(invalidateCache: true)
    }

    private func commitSliderValues() {
        settings.opacity = CGFloat(opacityRow.slider.value)
        settings.rotation = CGFloat(rotationRow.slider.value)
        settings.spacing = CGFloat(spacingRow.slider.value)
        switch settings.mode {
        case .tiled:
            settings.tiledScale = CGFloat(sizeRow.slider.value)
        case .corner:
            settings.cornerScale = CGFloat(sizeRow.slider.value)
        case .card:
            settings.frameBorderPercent = CGFloat(borderWidthRow.slider.value)
            settings.frameShowsCaption = frameCaptionSwitch.isOn
        case .retouch:
            settings.retouchBrushSize = brushDiameter(fromPercent: brushSizeRow.slider.value)
        }
    }

    private func updateLiveWatermarkPreview() {
        switch settings.mode {
        case .tiled, .corner:
            guard let preview = currentPreviewView(), preview.usesLayeredPreview else { return }
            preview.applyWatermarkLiveAdjustments(
                opacity: CGFloat(opacityRow.slider.value),
                scale: CGFloat(sizeRow.slider.value),
                committedScale: committedScale,
                mode: settings.mode,
                cornerPosition: settings.cornerPosition
            )
        case .card, .retouch:
            break
        }
    }

    private func syncCommittedPreviewValues() {
        committedOpacity = settings.opacity
        committedRotation = settings.rotation
        committedSpacing = settings.spacing
        switch settings.mode {
        case .tiled:
            committedScale = settings.tiledScale
        case .corner:
            committedScale = settings.cornerScale
        case .card, .retouch:
            committedScale = 1
        }
    }

    private func invalidateSpacingPreviewCache() {
        cachedSpacingPreviewSource = nil
        cachedSpacingPreviewBase = nil
        cachedSpacingPreviewIndex = nil
    }

    private func spacingPreviewCanvas(for source: UIImage, index: Int) -> (source: UIImage, base: UIImage) {
        if cachedSpacingPreviewIndex == index,
           let cachedSource = cachedSpacingPreviewSource,
           let cachedBase = cachedSpacingPreviewBase {
            return (cachedSource, cachedBase)
        }
        let downsampled = ImageLoader.downsample(
            source,
            maxPixelSize: ImageLimits.previewMaxPixelSize
        )
        let base = ImageLoader.normalized(downsampled)
        cachedSpacingPreviewSource = downsampled
        cachedSpacingPreviewBase = base
        cachedSpacingPreviewIndex = index
        return (downsampled, base)
    }

    private func overlaySettingsForLivePreview() -> WatermarkSettings? {
        var previewSettings = settings
        previewSettings.opacity = 1.0
        switch settings.mode {
        case .tiled:
            previewSettings.rotation = CGFloat(rotationRow.slider.value)
            previewSettings.spacing = CGFloat(spacingRow.slider.value)
            previewSettings.tiledScale = CGFloat(sizeRow.slider.value)
            return previewSettings
        case .corner:
            previewSettings.cornerScale = CGFloat(sizeRow.slider.value)
            previewSettings.cornerPosition = CornerPosition(
                rawValue: cornerPositionControl.selectedSegmentIndex
            ) ?? settings.cornerPosition
            return previewSettings
        case .card, .retouch:
            return nil
        }
    }

    private func scheduleOverlayRefresh() {
        overlayRenderQueued = true
        guard !overlayRenderInFlight else { return }
        performOverlayRender()
    }

    private func performOverlayRender() {
        guard overlayRenderQueued else { return }
        guard settings.mode == .tiled || settings.mode == .corner,
              let overlaySettings = overlaySettingsForLivePreview() else { return }

        overlayRenderQueued = false
        overlayRenderInFlight = true

        let index = currentIndex
        let source = images[index]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let canvas = self.spacingPreviewCanvas(for: source, index: index)
            guard let overlay = WatermarkEngine.renderWatermarkOverlay(
                for: canvas.source,
                settings: overlaySettings
            ) else {
                DispatchQueue.main.async { self.finishOverlayRender() }
                return
            }

            DispatchQueue.main.async {
                guard self.currentIndex == index else {
                    self.finishOverlayRender()
                    return
                }
                self.currentPreviewView()?.updatePreviewLayers(base: canvas.base, overlay: overlay)
                switch overlaySettings.mode {
                case .tiled:
                    self.committedRotation = overlaySettings.rotation
                    self.committedSpacing = overlaySettings.spacing
                    self.committedScale = overlaySettings.tiledScale
                case .corner:
                    self.committedScale = overlaySettings.cornerScale
                case .card, .retouch:
                    break
                }
                self.updateLiveWatermarkPreview()
                self.finishOverlayRender()
            }
        }
    }

    private func finishOverlayRender() {
        overlayRenderInFlight = false
        if overlayRenderQueued {
            performOverlayRender()
        }
    }

    @objc private func chooseLogoTapped() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func clearLogoTapped() {
        settings.setLogo(nil, for: settings.mode)
        updateLogoControls()
        refreshPreview(invalidateCache: true)
    }

    private func updatePageLabel() {
        let isRetouch = settings.mode == .retouch
        if images.count > 1 {
            if isRetouch {
                pageLabel.text = L10n.photoPageRetouch(index: currentIndex + 1, total: images.count)
            } else {
                pageLabel.text = L10n.photoPageScroll(index: currentIndex + 1, total: images.count)
            }
        } else {
            pageLabel.text = L10n.photoPageSingle
        }
        updatePhotoNavButtons()
    }

    private func updatePhotoNavButtons() {
        let showNav = settings.mode == .retouch && images.count > 1
        photoNavStack.isHidden = !showNav
        guard showNav else { return }

        let canGoPrevious = currentIndex > 0
        let canGoNext = currentIndex < images.count - 1
        previousPhotoButton.isEnabled = canGoPrevious
        nextPhotoButton.isEnabled = canGoNext
        previousPhotoButton.alpha = canGoPrevious ? 1 : 0.4
        nextPhotoButton.alpha = canGoNext ? 1 : 0.4
    }

    @objc private func previousPhotoTapped() {
        goToPhoto(at: currentIndex - 1)
    }

    @objc private func nextPhotoTapped() {
        goToPhoto(at: currentIndex + 1)
    }

    private func goToPhoto(at index: Int) {
        guard index >= 0, index < images.count, index != currentIndex else { return }
        hideBrushSizeIndicator()

        // Stop drawing on the outgoing page before the cell may be recycled.
        photoPager.previewView(at: currentIndex)?.isRetouchDrawingEnabled = false
        photoPager.previewView(at: currentIndex)?.retouchDelegate = nil

        currentIndex = index
        // Non-animated jump is safer while swipe paging is locked (Retouch).
        photoPager.scrollToPage(index, animated: false)
        invalidateSpacingPreviewCache()
        updatePageLabel()
        updateUndoRetouchButton()

        if let cell = photoPager.cell(at: index) {
            configurePhotoPage(cell: cell, at: index)
        }

        updateRetouchInteraction()
        if settings.mode == .retouch {
            refreshRetouchPreview(at: index)
        } else {
            refreshPreview(showSpinner: previewCache[index] == nil)
        }
    }
    @objc private func saveAllTapped() {
        guard TrialManager.shared.canSaveBatch() else {
            presentPurchase()
            return
        }

        commitSliderValues()
        let renderSettings = settings

        let progressVC = SaveProgressViewController(totalCount: images.count)
        progressVC.onComplete = { [weak self] success, message in
            progressVC.dismiss(animated: true) {
                guard let self, let message else { return }
                let title = success ? L10n.saved : L10n.saveFailed
                self.showAlert(title: title, message: message)
            }
        }
        present(progressVC, animated: true)

        progressVC.renderImages(
            sources: images,
            settings: renderSettings,
            retouchStrokePaths: retouchNormalizedStrokePaths
        ) { outputs in
            let shouldConsume = !TrialManager.shared.isUnlocked
            progressVC.saveToLibrary(outputs, consumeTrialIfNeeded: shouldConsume)
        }
    }

    // MARK: - Helpers

    private func presentPurchase() {
        let purchaseVC = PurchaseViewController()
        let nav = UINavigationController(rootViewController: purchaseVC)
        nav.modalPresentationStyle = .formSheet
        purchaseVC.onUnlocked = { [weak self] in
            self?.navigationItem.rightBarButtonItem?.isEnabled = true
        }
        present(nav, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
        present(alert, animated: true)
    }

    private func applyWatermarkTextFieldStyle() {
        textField.placeholder = L10n.watermarkTextPlaceholder
        textField.backgroundColor = AppTheme.fieldBackground
        textField.layer.borderWidth = 1
        textField.layer.borderColor = AppTheme.fieldBorder.cgColor
    }

    private func applyFrameCaptionFieldStyle() {
        textField.placeholder = L10n.captionOnCardPlaceholder
        textField.backgroundColor = AppTheme.fieldBackground
        textField.layer.borderWidth = 1.5
        textField.layer.borderColor = AppTheme.accent.withAlphaComponent(0.35).cgColor
    }

    private func updateModeControls() {
        let isTiled = settings.mode == .tiled
        let isCorner = settings.mode == .corner
        let isCard = settings.mode == .card
        let isRetouch = settings.mode == .retouch

        rotationRow.isHidden = !isTiled
        spacingRow.isHidden = !isTiled
        opacityRow.isHidden = isCard || isRetouch
        sizeRow.isHidden = isCard || isRetouch
        borderWidthRow.isHidden = !isCard
        frameCaptionRow.isHidden = !isCard
        brushSizeRow.isHidden = !isRetouch
        retouchColorHeaderLabel.isHidden = !isRetouch
        retouchColorContainer.isHidden = !isRetouch
        cornerHeaderLabel.isHidden = !isCorner
        cornerPositionControl.isHidden = !isCorner
        templateHeaderLabel.isHidden = true
        templateCollectionView.isHidden = true
        textField.isHidden = isCorner || isRetouch
        logoButton.isHidden = !isCorner
        clearLogoButton.isHidden = !isCorner || settings.logo(for: settings.mode) == nil

        if !isRetouch {
            hideBrushSizeIndicator()
            navigationItem.rightBarButtonItems = [saveAllBarButton]
        } else {
            navigationItem.rightBarButtonItems = [saveAllBarButton, undoRetouchBarButton]
            updateUndoRetouchButton()
        }

        if isCorner {
            view.endEditing(true)
        } else if isRetouch {
            view.endEditing(true)
        }

        if isCard {
            applyFrameCaptionFieldStyle()
        } else if isTiled {
            applyWatermarkTextFieldStyle()
        }

        if isTiled {
            sizeRow.configure(
                min: 0.5,
                max: 2.5,
                value: Float(settings.tiledScale)
            )
        } else if isCorner {
            sizeRow.configure(
                min: 0.05,
                max: 0.35,
                value: Float(settings.cornerScale)
            )
        } else if isCard {
            borderWidthRow.configure(
                min: 2,
                max: 18,
                value: Float(settings.frameBorderPercent)
            )
            frameCaptionSwitch.isOn = settings.frameShowsCaption
        } else if isRetouch {
            brushSizeRow.configure(
                min: 0,
                max: 100,
                value: brushPercent(fromDiameter: settings.retouchBrushSize)
            )
            updateRetouchColorSelection()
            MIGANInpaintEngine.prepareModel()
        }
    }

    private func setupRetouchColorPicker() {
        for (index, color) in Self.retouchBrushColors.enumerated() {
            let button = UIButton(type: .custom)
            button.tag = index
            button.backgroundColor = color
            button.layer.cornerRadius = 16
            button.layer.borderWidth = 2
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            button.addTarget(self, action: #selector(retouchColorTapped(_:)), for: .touchUpInside)
            retouchColorButtons.append(button)
            retouchColorStack.addArrangedSubview(button)
        }
        updateRetouchColorSelection()
    }

    @objc private func retouchColorTapped(_ sender: UIButton) {
        settings.retouchBrushColorIndex = sender.tag
        updateRetouchColorSelection()
        if brushSizeRow.slider.isTracking {
            showBrushSizeIndicator()
        }
    }

    private func brushDiameter(fromPercent percent: Float) -> CGFloat {
        let t = CGFloat(min(max(percent, 0), 100) / 100)
        return Self.retouchBrushDiameterAtZeroPercent
            + (Self.retouchBrushDiameterAtFullPercent - Self.retouchBrushDiameterAtZeroPercent) * t
    }

    private func brushPercent(fromDiameter diameter: CGFloat) -> Float {
        let span = Self.retouchBrushDiameterAtFullPercent - Self.retouchBrushDiameterAtZeroPercent
        guard span > 0 else { return 0 }
        let t = (diameter - Self.retouchBrushDiameterAtZeroPercent) / span
        return Float(min(max(t, 0), 1) * 100)
    }

    private func showBrushSizeIndicator() {
        guard settings.mode == .retouch,
              let preview = currentPreviewView() else { return }
        let diameter = brushDiameter(fromPercent: brushSizeRow.slider.value)
        preview.showBrushSizeIndicator(diameter: diameter, color: selectedRetouchColor())
    }

    private func hideBrushSizeIndicator() {
        for index in 0..<images.count {
            photoPager.previewView(at: index)?.hideBrushSizeIndicator()
        }
    }

    private func updateRetouchColorSelection() {
        for button in retouchColorButtons {
            let selected = button.tag == settings.retouchBrushColorIndex
            button.layer.borderColor = selected
                ? AppTheme.primaryText.cgColor
                : UIColor.clear.cgColor
            button.transform = selected ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
        }
    }

    private func selectedRetouchColor() -> UIColor {
        let index = min(max(settings.retouchBrushColorIndex, 0), Self.retouchBrushColors.count - 1)
        return Self.retouchBrushColors[index]
    }

    private func updateLogoControls() {
        let supportsLogo = settings.mode == .corner
        logoButton.isHidden = !supportsLogo
        clearLogoButton.isHidden = !supportsLogo || settings.logo(for: settings.mode) == nil
    }

    // MARK: - Retouch

    private func updateRetouchInteraction() {
        let isRetouch = settings.mode == .retouch
        // Retouch never uses swipe paging — Previous/Next buttons switch photos instead.
        photoPager.isPagingEnabled = !isRetouch && images.count > 1

        for index in 0..<images.count {
            guard let preview = photoPager.previewView(at: index) else { continue }
            preview.isRetouchDrawingEnabled = isRetouch && index == currentIndex
            preview.retouchDelegate = isRetouch ? self : nil
        }
        updatePhotoNavButtons()
    }

    private func refreshRetouchPreview(at index: Int) {
        guard settings.mode == .retouch else { return }
        guard baseImageCache[index] != nil else {
            configurePhotoPage(at: index)
            return
        }

        guard photoPager.cell(at: index)?.photoIndex == index else {
            updateRetouchInteraction()
            return
        }

        showRetouchDisplay(at: index)
        updateRetouchInteraction()
    }

    private func showRetouchDisplay(at index: Int) {
        guard let base = baseImageCache[index],
              let cell = photoPager.cell(at: index),
              cell.photoIndex == index else { return }

        let composite = retouchCompositeCache[index] ?? base
        let preview = WatermarkEngine.compositeRetouchPreview(
            base: composite,
            mask: retouchMaskCache[index]
        )
        cell.zoomablePreview.updateRetouchPreview(preview, referenceSize: base.size)
    }

    private func beginRetouchStroke(at point: CGPoint, index: Int) {
        retouchActiveStroke[index] = [point]
        retouchMaskCache[index] = nil
    }

    private func extendRetouchStroke(from start: CGPoint, to end: CGPoint, at index: Int) {
        guard let base = baseImageCache[index] else { return }

        var points = retouchActiveStroke[index] ?? []
        if points.isEmpty {
            points.append(start)
        }
        points.append(end)
        retouchActiveStroke[index] = points

        let brushSize = settings.retouchBrushSize
        retouchMaskCache[index] = WatermarkEngine.drawMaskStroke(
            on: retouchMaskCache[index],
            canvasSize: base.size,
            scale: base.scale,
            from: start,
            to: end,
            brushDiameter: brushSize,
            color: selectedRetouchColor()
        )
        showRetouchDisplay(at: index)
    }

    private func commitRetouchStroke(at index: Int) {
        guard let base = baseImageCache[index],
              let points = retouchActiveStroke[index],
              !points.isEmpty else { return }

        pushRetouchUndoSnapshot(at: index)
        recordNormalizedStrokePath(points, at: index)
        retouchActiveStroke[index] = []
        // Keep colored mask until AI fill lands so the stroke never flashes away.
        previewSpinner.startAnimating()
        updateUndoRetouchButton()

        let generation = (retouchCommitGeneration[index] ?? 0) + 1
        retouchCommitGeneration[index] = generation

        let brushSize = settings.retouchBrushSize
        let existingComposite = retouchCompositeCache[index] ?? base

        retouchQuickQueue.async { [weak self] in
            guard let self else { return }
            let result = WatermarkEngine.commitRetouchPath(
                on: existingComposite,
                originalBase: base,
                points: points,
                brushDiameter: brushSize
            )
            DispatchQueue.main.async {
                guard self.retouchCommitGeneration[index] == generation else { return }
                self.retouchCompositeCache[index] = result
                self.retouchMaskCache[index] = nil
                if self.currentIndex == index, self.settings.mode == .retouch {
                    self.showRetouchDisplay(at: index)
                }
                self.previewSpinner.stopAnimating()
                self.updateUndoRetouchButton()
            }
        }
    }

    private func recordNormalizedStrokePath(_ points: [CGPoint], at index: Int) {
        guard let base = baseImageCache[index] else { return }

        var path: [CGPoint] = []
        path.reserveCapacity(points.count)
        for point in points {
            let normalized = WatermarkEngine.normalizedPoint(point, imageSize: base.size)
            if path.isEmpty {
                path.append(normalized)
            } else if distanceBetween(path.last!, normalized) > 0.0001 {
                path.append(normalized)
            }
        }
        guard !path.isEmpty else { return }

        var paths = retouchNormalizedStrokePaths[index] ?? []
        paths.append(path)
        retouchNormalizedStrokePaths[index] = paths
    }

    private func pushRetouchUndoSnapshot(at index: Int) {
        var stack = retouchUndoSnapshots[index] ?? []
        stack.append(retouchCompositeCache[index])
        if stack.count > Self.maxRetouchUndosPerPhoto {
            stack.removeFirst(stack.count - Self.maxRetouchUndosPerPhoto)
        }
        retouchUndoSnapshots[index] = stack
    }

    @objc private func undoRetouchTapped() {
        undoLastRetouchStroke(at: currentIndex)
    }

    private func undoLastRetouchStroke(at index: Int) {
        guard var stack = retouchUndoSnapshots[index], let snapshot = stack.popLast() else { return }
        retouchUndoSnapshots[index] = stack

        // Cancel any in-flight AI fill for this photo.
        retouchCommitGeneration[index] = (retouchCommitGeneration[index] ?? 0) + 1
        previewSpinner.stopAnimating()
        retouchActiveStroke[index] = []
        retouchMaskCache[index] = nil

        if let snapshot {
            retouchCompositeCache[index] = snapshot
        } else {
            retouchCompositeCache[index] = nil
        }

        if var paths = retouchNormalizedStrokePaths[index], !paths.isEmpty {
            paths.removeLast()
            retouchNormalizedStrokePaths[index] = paths
        }

        if settings.mode == .retouch, currentIndex == index {
            showRetouchDisplay(at: index)
        }
        updateUndoRetouchButton()
    }

    private func updateUndoRetouchButton() {
        let canUndo = settings.mode == .retouch
            && !(retouchUndoSnapshots[currentIndex] ?? []).isEmpty
        undoRetouchBarButton.isEnabled = canUndo
    }

    private func distanceBetween(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    // MARK: - Preview cache

    private func invalidateAllPreviewCaches() {
        previewCache.removeAll()
        invalidateSpacingPreviewCache()
    }

    private func preloadBaseImages() {
        let sources = images
        let priorityIndex = currentIndex

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            func downsampled(_ image: UIImage) -> UIImage {
                ImageLoader.normalized(
                    ImageLoader.downsample(image, maxPixelSize: ImageLimits.previewMaxPixelSize)
                )
            }

            if priorityIndex < sources.count {
                let first = downsampled(sources[priorityIndex])
                DispatchQueue.main.async {
                    self.baseImageCache[priorityIndex] = first
                    self.configurePhotoPage(at: priorityIndex)
                }
            }

            var loaded: [Int: UIImage] = [:]
            for (index, source) in sources.enumerated() where index != priorityIndex {
                loaded[index] = downsampled(source)
            }

            DispatchQueue.main.async {
                for (index, image) in loaded {
                    self.baseImageCache[index] = image
                    if self.previewCache[index] == nil {
                        self.configurePhotoPage(at: index)
                    }
                }
            }
        }
    }

    private func previewSettingsForRender() -> WatermarkSettings {
        var currentSettings = settings
        if currentSettings.mode == .card {
            currentSettings.frameBorderPercent = CGFloat(borderWidthRow.slider.value)
            currentSettings.frameShowsCaption = frameCaptionSwitch.isOn
        }
        return currentSettings
    }

    private func renderPreview(for index: Int, settings renderSettings: WatermarkSettings) -> CachedPreview {
        let previewSource: UIImage
        if let cachedBase = baseImageCache[index] {
            previewSource = cachedBase
        } else {
            previewSource = ImageLoader.normalized(
                ImageLoader.downsample(images[index], maxPixelSize: ImageLimits.previewMaxPixelSize)
            )
        }

        switch renderSettings.mode {
        case .tiled, .corner:
            let base = previewSource
            if let overlay = WatermarkEngine.renderWatermarkOverlay(
                for: previewSource,
                settings: renderSettings
            ) {
                return .layered(base: base, overlay: overlay)
            }
            return .flat(base)
        case .card:
            let rendered = WatermarkEngine.applyWatermark(to: previewSource, settings: renderSettings)
            return .flat(rendered)
        case .retouch:
            let base = previewSource
            if let composite = retouchCompositeCache[index] {
                return .flat(composite)
            }
            return .flat(base)
        }
    }

    private func applyCachedPreview(_ preview: CachedPreview, to cell: EditPhotoPagerCell) {
        guard cell.photoIndex >= 0 else { return }
        switch preview {
        case .flat(let image):
            cell.zoomablePreview.image = image
        case .layered(let base, let overlay):
            cell.zoomablePreview.setLayeredPreview(base: base, overlay: overlay)
        }
    }

    private func applyCachedPreview(_ preview: CachedPreview, at index: Int) {
        guard let cell = photoPager.cell(at: index), cell.photoIndex == index else { return }
        applyCachedPreview(preview, to: cell)
    }

    private func configurePhotoPage(at index: Int) {
        if let cell = photoPager.cell(at: index), cell.photoIndex == index {
            configurePhotoPage(cell: cell, at: index)
        }
    }

    private func configurePhotoPage(cell: EditPhotoPagerCell, at index: Int) {
        cell.prepareForPhoto(at: index)
        if settings.mode == .retouch {
            if let base = baseImageCache[index] {
                let composite = retouchCompositeCache[index] ?? base
                let preview = WatermarkEngine.compositeRetouchPreview(
                    base: composite,
                    mask: retouchMaskCache[index]
                )
                cell.zoomablePreview.updateRetouchPreview(preview, referenceSize: base.size)
            } else {
                cell.zoomablePreview.image = nil
            }
            cell.zoomablePreview.isRetouchDrawingEnabled = index == currentIndex
            cell.zoomablePreview.retouchDelegate = self
            return
        }

        cell.zoomablePreview.isRetouchDrawingEnabled = false
        cell.zoomablePreview.retouchDelegate = nil
        if let cached = previewCache[index] {
            applyCachedPreview(cached, to: cell)
        } else if let base = baseImageCache[index] {
            cell.zoomablePreview.image = base
        } else {
            cell.zoomablePreview.image = nil
        }
    }

    private func schedulePreviewPreload() {
        previewPreloadGeneration += 1
        let generation = previewPreloadGeneration
        let renderSettings = previewSettingsForRender()
        let count = images.count

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for index in 0..<count {
                if generation != self.previewPreloadGeneration { return }
                let rendered = self.renderPreview(for: index, settings: renderSettings)
                DispatchQueue.main.async {
                    guard generation == self.previewPreloadGeneration else { return }
                    self.previewCache[index] = rendered
                    self.applyCachedPreview(rendered, at: index)
                    if index == self.currentIndex {
                        self.previewSpinner.stopAnimating()
                        self.syncCommittedPreviewValues()
                        self.updateLiveWatermarkPreview()
                    }
                }
            }
        }
    }

    private func refreshPreview(invalidateCache: Bool = false, showSpinner: Bool = true) {
        if settings.mode == .retouch {
            previewSpinner.stopAnimating()
            refreshRetouchPreview(at: currentIndex)
            updateRetouchInteraction()
            return
        }

        if invalidateCache {
            invalidateAllPreviewCaches()
            schedulePreviewPreload()
        }

        let index = currentIndex
        if let cached = previewCache[index] {
            applyCachedPreview(cached, at: index)
            syncCommittedPreviewValues()
            updateLiveWatermarkPreview()
            previewSpinner.stopAnimating()
            return
        }

        previewTask?.cancel()
        overlayRenderQueued = false
        let renderSettings = previewSettingsForRender()

        if showSpinner {
            previewSpinner.startAnimating()
        }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let rendered = self.renderPreview(for: index, settings: renderSettings)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentIndex == index else { return }
                self.previewCache[index] = rendered
                self.applyCachedPreview(rendered, at: index)
                self.previewSpinner.stopAnimating()
                self.syncCommittedPreviewValues()
                self.updateLiveWatermarkPreview()
            }
        }
        previewTask = task
        DispatchQueue.global(qos: .userInitiated).async(execute: task)
    }

    private func refreshPreview(showSpinner: Bool = true) {
        refreshPreview(invalidateCache: false, showSpinner: showSpinner)
    }
}

// MARK: - Photo Pager

extension EditViewController: EditPhotoPagerViewDataSource {
    func photoPager(_ pager: EditPhotoPagerView, configure cell: EditPhotoPagerCell, at index: Int) {
        configurePhotoPage(cell: cell, at: index)
    }
}

extension EditViewController: EditPhotoPagerViewDelegate {
    func photoPager(_ pager: EditPhotoPagerView, didScrollToPage index: Int) {
        guard index != currentIndex else { return }
        currentIndex = index
        invalidateSpacingPreviewCache()
        updatePageLabel()
        updateUndoRetouchButton()
        if settings.mode == .retouch {
            refreshRetouchPreview(at: index)
        } else {
            refreshPreview(showSpinner: previewCache[index] == nil)
        }
    }
}

extension EditViewController: ZoomableImageViewRetouchDelegate {
    func zoomableImageView(_ view: ZoomableImageView, didBeginStrokeAt point: CGPoint) {
        guard settings.mode == .retouch else { return }
        beginRetouchStroke(at: point, index: currentIndex)
    }

    func zoomableImageView(_ view: ZoomableImageView, didStrokeFrom start: CGPoint, to end: CGPoint) {
        guard settings.mode == .retouch else { return }
        extendRetouchStroke(from: start, to: end, at: currentIndex)
    }

    func zoomableImageViewDidEndStroke(_ view: ZoomableImageView) {
        guard settings.mode == .retouch else { return }
        commitRetouchStroke(at: currentIndex)
    }
}

// MARK: - Navigation

extension EditViewController: UIGestureRecognizerDelegate {
    private func disableNavigationSwipeBack() {
        guard let navigationController else { return }

        if let edgePop = navigationController.interactivePopGestureRecognizer {
            savedInteractivePopEnabled = edgePop.isEnabled
            edgePop.isEnabled = false
            edgePop.delegate = self
        }

        if #available(iOS 26.0, *) {
            if let contentPop = navigationController.interactiveContentPopGestureRecognizer {
                savedInteractiveContentPopEnabled = contentPop.isEnabled
                contentPop.isEnabled = false
                contentPop.cancelsTouchesInView = false
                contentPop.delegate = self
            }
        }
    }

    private func restoreNavigationSwipeBack() {
        guard let navigationController else { return }

        navigationController.interactivePopGestureRecognizer?.isEnabled = savedInteractivePopEnabled
        navigationController.interactivePopGestureRecognizer?.delegate = nil

        if #available(iOS 26.0, *) {
            navigationController.interactiveContentPopGestureRecognizer?.isEnabled = savedInteractiveContentPopEnabled
            navigationController.interactiveContentPopGestureRecognizer?.delegate = nil
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigationController else { return true }

        if gestureRecognizer === navigationController.interactivePopGestureRecognizer {
            return false
        }

        if #available(iOS 26.0, *) {
            if gestureRecognizer === navigationController.interactiveContentPopGestureRecognizer {
                return false
            }
        }

        return true
    }
}

/// Keeps UISlider interaction from being cancelled by the controls UIScrollView.
private final class ControlsScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UISlider || view.superview is UISlider {
            return false
        }
        return super.touchesShouldCancel(in: view)
    }
}

// MARK: - PHPicker (Logo)

extension EditViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else { return }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
            guard let data,
                  let image = ImageLoader.image(from: data, maxPixelSize: ImageLimits.pickerMaxPixelSize) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.settings.setLogo(image, for: self.settings.mode)
                self.updateLogoControls()
                self.refreshPreview(invalidateCache: true)
            }
        }
    }
}

// MARK: - Device Template Collection

extension EditViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        DeviceFrameTemplate.allCases.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: DeviceFrameTemplateCell.reuseID,
            for: indexPath
        ) as! DeviceFrameTemplateCell
        let template = DeviceFrameTemplate.allCases[indexPath.item]
        cell.configure(template: template, selected: template == settings.deviceTemplate)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        settings.deviceTemplate = DeviceFrameTemplate.allCases[indexPath.item]
        collectionView.reloadData()
        refreshPreview(invalidateCache: true)
    }
}
