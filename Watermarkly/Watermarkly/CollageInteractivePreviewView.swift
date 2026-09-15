import UIKit

protocol CollageInteractivePreviewViewDelegate: AnyObject {
    func collagePreview(_ preview: CollageInteractivePreviewView, didSwapSlot from: Int, with to: Int)
    func collagePreview(_ preview: CollageInteractivePreviewView, didUpdateAdjustment: CollageCellAdjustment, forSlot slotIndex: Int)
    func collagePreviewSelectionDidChange(_ preview: CollageInteractivePreviewView)
}

final class CollageInteractivePreviewView: UIView {

    weak var delegate: CollageInteractivePreviewViewDelegate?

    private var images: [UIImage] = []
    private var options = CollageLayoutOptions()
    private var selectedSlotIndex: Int?
    private var cellViews: [CollageEditableCellView] = []
    private var layout = CollageComputedLayout(canvasSize: .zero, spacing: 5, slots: [])

    private let backgroundImageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        return view
    }()

    private var dragSnapshot: UIView?
    private var dragSourceSlot: Int?
    private var dropTargetSlot: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = AppTheme.cornerRadius
        layer.borderWidth = 1
        layer.borderColor = AppTheme.fieldBorder.cgColor
        addSubview(backgroundImageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundImageView.frame = bounds
        relayoutCells()
    }

    func configure(images: [UIImage], options: CollageLayoutOptions) {
        self.images = images
        self.options = options
        selectedSlotIndex = nil
        rebuildCells()
        updateBackground()
        setNeedsLayout()
    }

    func selectedSlot() -> Int? { selectedSlotIndex }

    func adjustment(for slotIndex: Int) -> CollageCellAdjustment {
        options.cellAdjustments[slotIndex] ?? CollageCellAdjustment()
    }

    func currentAdjustments() -> [Int: CollageCellAdjustment] {
        options.cellAdjustments
    }

    func applyAdjustment(_ adjustment: CollageCellAdjustment, forSlot slotIndex: Int) {
        options.cellAdjustments[slotIndex] = adjustment
        cellViews.first(where: { $0.slotIndex == slotIndex })?.apply(
            adjustment: adjustment,
            selected: slotIndex == selectedSlotIndex
        )
    }

    // MARK: - Private

    private func rebuildCells() {
        cellViews.forEach { $0.removeFromSuperview() }
        cellViews.removeAll()

        layout = CollageLayoutEngine.computeLayout(imageCount: images.count, options: options)

        for slot in layout.slots where slot.imageIndex < images.count {
            let cell = CollageEditableCellView(
                slotIndex: slot.slotIndex,
                image: images[slot.imageIndex],
                padColor: options.cellPadColor
            )
            cell.adjustment = options.cellAdjustments[slot.slotIndex] ?? CollageCellAdjustment()
            cell.isSlotSelected = slot.slotIndex == selectedSlotIndex
            cell.onTap = { [weak self] index in self?.selectSlot(index) }
            cell.onAdjustmentChanged = { [weak self] index, adjustment in
                guard let self else { return }
                self.options.cellAdjustments[index] = adjustment
                self.delegate?.collagePreview(self, didUpdateAdjustment: adjustment, forSlot: index)
            }
            cell.onReorderRequested = { [weak self] index, gesture in
                self?.handleReorder(gesture: gesture, sourceSlot: index)
            }
            addSubview(cell)
            cellViews.append(cell)
        }
        relayoutCells()
    }

    private func relayoutCells() {
        guard bounds.width > 0, bounds.height > 0, layout.canvasSize.width > 0 else { return }

        let scaleX = bounds.width / layout.canvasSize.width
        let scaleY = bounds.height / layout.canvasSize.height

        for cell in cellViews {
            guard let slot = layout.slots.first(where: { $0.slotIndex == cell.slotIndex }) else { continue }
            cell.frame = CGRect(
                x: slot.rect.minX * scaleX,
                y: slot.rect.minY * scaleY,
                width: slot.rect.width * scaleX,
                height: slot.rect.height * scaleY
            )
            cell.setNeedsLayout()
        }
    }

    private func updateBackground() {
        switch options.backgroundStyle {
        case .white:
            backgroundColor = .white
            backgroundImageView.image = nil
            backgroundImageView.isHidden = true
        case .lightGray:
            backgroundColor = UIColor(white: 0.94, alpha: 1)
            backgroundImageView.image = nil
            backgroundImageView.isHidden = true
        case .blurred:
            backgroundColor = .white
            backgroundImageView.isHidden = false
            if let first = images.first {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let blurred = CollageLayoutEngine.previewBlurredBackground(from: first, size: self?.bounds.size ?? CGSize(width: 400, height: 400))
                    DispatchQueue.main.async {
                        self?.backgroundImageView.image = blurred
                    }
                }
            }
        }
    }

    private func selectSlot(_ index: Int) {
        selectedSlotIndex = index
        cellViews.forEach { $0.isSlotSelected = ($0.slotIndex == index) }
        delegate?.collagePreviewSelectionDidChange(self)
    }

    private func handleReorder(gesture: UILongPressGestureRecognizer, sourceSlot: Int) {
        let location = gesture.location(in: self)

        switch gesture.state {
        case .began:
            dragSourceSlot = sourceSlot
            selectedSlotIndex = nil
            cellViews.forEach { $0.isSlotSelected = false }

            guard let cell = cellViews.first(where: { $0.slotIndex == sourceSlot }) else { return }
            let snapshot = cell.snapshotView(afterScreenUpdates: true) ?? UIView()
            snapshot.frame = cell.frame
            snapshot.layer.cornerRadius = 6
            snapshot.layer.shadowColor = UIColor.black.cgColor
            snapshot.layer.shadowOpacity = 0.25
            snapshot.layer.shadowRadius = 8
            addSubview(snapshot)
            dragSnapshot = snapshot
            cell.alpha = 0.35

        case .changed:
            dragSnapshot?.center = location
            let target = slotIndex(at: location)
            dropTargetSlot = target
            cellViews.forEach { view in
                view.layer.borderWidth = view.slotIndex == target && target != dragSourceSlot ? 2 : 0
            }

        case .ended, .cancelled, .failed:
            defer { cleanupDrag() }
            guard let from = dragSourceSlot,
                  let to = dropTargetSlot,
                  from != to else { return }
            delegate?.collagePreview(self, didSwapSlot: from, with: to)

        default:
            break
        }
    }

    private func slotIndex(at point: CGPoint) -> Int? {
        cellViews.first(where: { $0.frame.contains(point) })?.slotIndex
    }

    private func cleanupDrag() {
        dragSnapshot?.removeFromSuperview()
        dragSnapshot = nil
        dragSourceSlot = nil
        dropTargetSlot = nil
        cellViews.forEach {
            $0.alpha = 1
            $0.layer.borderWidth = 0
        }
    }
}

// MARK: - Editable cell

private final class CollageEditableCellView: UIView {

    var slotIndex: Int
    var adjustment: CollageCellAdjustment = CollageCellAdjustment() {
        didSet { setNeedsLayout() }
    }
    var isSlotSelected = false {
        didSet {
            updateSelectionChrome()
            panGesture.isEnabled = isSlotSelected
            pinchGesture.isEnabled = isSlotSelected
        }
    }

    var onTap: ((Int) -> Void)?
    var onAdjustmentChanged: ((Int, CollageCellAdjustment) -> Void)?
    var onReorderRequested: ((Int, UILongPressGestureRecognizer) -> Void)?

    private let imageView = UIImageView()
    private let image: UIImage
    private let padColor: UIColor
    private let panGesture: UIPanGestureRecognizer
    private let pinchGesture: UIPinchGestureRecognizer

    private var panStartOffset: CGPoint = .zero
    private var pinchStartScale: CGFloat = 1

    init(slotIndex: Int, image: UIImage, padColor: UIColor) {
        self.slotIndex = slotIndex
        self.image = image
        self.padColor = padColor
        self.panGesture = UIPanGestureRecognizer()
        self.pinchGesture = UIPinchGestureRecognizer()
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = padColor

        imageView.contentMode = .scaleToFill
        imageView.image = image
        addSubview(imageView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        addGestureRecognizer(longPress)

        panGesture.addTarget(self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        panGesture.isEnabled = false
        addGestureRecognizer(panGesture)

        pinchGesture.addTarget(self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        pinchGesture.isEnabled = false
        addGestureRecognizer(pinchGesture)

        tap.require(toFail: longPress)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(adjustment: CollageCellAdjustment, selected: Bool) {
        self.adjustment = adjustment
        self.isSlotSelected = selected
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frame = CollageLayoutEngine.drawFrame(
            for: image,
            in: bounds,
            adjustment: adjustment
        )
        imageView.frame = frame
    }

    private func updateSelectionChrome() {
        layer.borderWidth = isSlotSelected ? 2 : 0
        layer.borderColor = AppTheme.accent.cgColor
    }

    @objc private func handleTap() {
        onTap?(slotIndex)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            onReorderRequested?(slotIndex, gesture)
        } else if gesture.state == .changed || gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            onReorderRequested?(slotIndex, gesture)
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isSlotSelected else { return }
        let translation = gesture.translation(in: self)

        switch gesture.state {
        case .began:
            panStartOffset = adjustment.offset
        case .changed, .ended:
            var next = adjustment
            next.offset = CGPoint(
                x: panStartOffset.x + translation.x,
                y: panStartOffset.y + translation.y
            )
            next.offset = clamp(offset: next.offset, scale: next.scale)
            adjustment = next
            if gesture.state == .ended {
                onAdjustmentChanged?(slotIndex, next)
            }
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard isSlotSelected else { return }

        switch gesture.state {
        case .began:
            pinchStartScale = adjustment.scale
        case .changed, .ended:
            var next = adjustment
            next.scale = max(1, pinchStartScale * gesture.scale)
            next.offset = clamp(offset: next.offset, scale: next.scale)
            adjustment = next
            if gesture.state == .ended {
                onAdjustmentChanged?(slotIndex, next)
            }
        default:
            break
        }
    }

    private func clamp(offset: CGPoint, scale: CGFloat) -> CGPoint {
        let frame = CollageLayoutEngine.drawFrame(
            for: image,
            in: bounds,
            adjustment: CollageCellAdjustment(scale: scale, offset: .zero)
        )
        let maxOffsetX = max(0, (frame.width - bounds.width) / 2)
        let maxOffsetY = max(0, (frame.height - bounds.height) / 2)
        return CGPoint(
            x: min(maxOffsetX, max(-maxOffsetX, offset.x)),
            y: min(maxOffsetY, max(-maxOffsetY, offset.y))
        )
    }
}

extension CollageEditableCellView: UIGestureRecognizerDelegate {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGesture || gestureRecognizer === pinchGesture {
            return isSlotSelected
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Let page scrolling win when the cell is not being adjusted.
        if !isSlotSelected, other.view is UIScrollView || other is UIPanGestureRecognizer {
            return true
        }
        return gestureRecognizer === pinchGesture || other is UIPinchGestureRecognizer
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}
