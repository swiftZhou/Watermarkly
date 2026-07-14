import UIKit

protocol ZoomableImageViewRetouchDelegate: AnyObject {
    func zoomableImageView(_ view: ZoomableImageView, didBeginStrokeAt point: CGPoint)
    func zoomableImageView(_ view: ZoomableImageView, didStrokeFrom start: CGPoint, to end: CGPoint)
    func zoomableImageViewDidEndStroke(_ view: ZoomableImageView)
}

final class ZoomableImageView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {

    private let contentView = UIView()
    private let baseImageView = UIImageView()
    private let overlayImageView = UIImageView()
    private let brushSizeIndicatorView: UIView = {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        view.alpha = 0.55
        view.layer.borderWidth = 2
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        return view
    }()

    private(set) var usesLayeredPreview = false
    var onZoomScaleChanged: ((CGFloat) -> Void)?
    weak var retouchDelegate: ZoomableImageViewRetouchDelegate?
    private var brushIndicatorDiameterInImage: CGFloat = 0

    var isRetouchDrawingEnabled = false {
        didSet {
            if oldValue && !isRetouchDrawingEnabled, retouchLiveScale > 1.01 {
                resetZoomCanvas()
            }
            applyRetouchInteractionMode()
        }
    }

    private var retouchLastPoint: CGPoint?
    private var retouchDidMove = false
    private var retouchReferenceSize: CGSize = .zero
    private var lastLayoutBounds: CGSize = .zero
    private var isRetouchTwoFingerActive = false
    private var retouchLiveScale: CGFloat = 1
    private var twoFingerInitialScale: CGFloat = 1
    private var twoFingerInitialAnchorContent: CGPoint = .zero
    private var twoFingerInitialDistance: CGFloat = 0

    private lazy var retouchPanGesture: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleRetouchPan(_:)))
        gesture.maximumNumberOfTouches = 1
        gesture.delegate = self
        gesture.isEnabled = false
        gesture.cancelsTouchesInView = false
        return gesture
    }()

    /// Douyin-style unified two-finger zoom + pan in one gesture.
    private lazy var retouchTwoFingerTransformGesture: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleRetouchTwoFingerTransform(_:)))
        gesture.minimumNumberOfTouches = 2
        gesture.maximumNumberOfTouches = 2
        gesture.delegate = self
        gesture.isEnabled = false
        gesture.cancelsTouchesInView = false
        return gesture
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 3
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        backgroundColor = .clear
        delaysContentTouches = false
        contentInsetAdjustmentBehavior = .never
        isMultipleTouchEnabled = true

        contentView.isMultipleTouchEnabled = true
        contentView.translatesAutoresizingMaskIntoConstraints = true
        baseImageView.translatesAutoresizingMaskIntoConstraints = true
        overlayImageView.translatesAutoresizingMaskIntoConstraints = true

        baseImageView.contentMode = .scaleAspectFit
        baseImageView.isUserInteractionEnabled = true
        baseImageView.isMultipleTouchEnabled = true
        baseImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        overlayImageView.contentMode = .scaleAspectFit
        overlayImageView.isUserInteractionEnabled = false
        overlayImageView.isHidden = true
        overlayImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        addSubview(contentView)
        contentView.addSubview(baseImageView)
        contentView.addSubview(overlayImageView)
        // Keep indicator on the scroll view (not contentView) so pinch-zoom
        // never moves it off-screen with the photo.
        addSubview(brushSizeIndicatorView)
        baseImageView.addGestureRecognizer(retouchPanGesture)
        addGestureRecognizer(retouchTwoFingerTransformGesture)
        pinchGestureRecognizer?.delegate = self
        panGestureRecognizer.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let sizeChanged = bounds.size != lastLayoutBounds
        if sizeChanged {
            lastLayoutBounds = bounds.size
        }

        if isRetouchDrawingEnabled && (isRetouchTwoFingerActive || retouchLiveScale > 1.01) {
            if sizeChanged {
                baseImageView.frame = CGRect(origin: .zero, size: bounds.size)
                overlayImageView.frame = baseImageView.bounds
                contentSize = bounds.size
            }
            layoutBrushSizeIndicator()
            return
        }

        if abs(zoomScale - 1) < 0.01, retouchLiveScale <= 1.01 {
            if sizeChanged || contentView.frame.size != bounds.size {
                applyInitialZoomLayout()
            }
        } else if sizeChanged, zoomScale <= 1.01 {
            centerContentIfNeeded()
        }
        layoutBrushSizeIndicator()
    }

    private func applyInitialZoomLayout() {
        contentView.transform = .identity
        contentView.frame = CGRect(origin: .zero, size: bounds.size)
        baseImageView.frame = contentView.bounds
        overlayImageView.frame = contentView.bounds
        contentSize = bounds.size
        if isRetouchDrawingEnabled {
            configureContentViewAnchorForRetouchTransform()
        } else {
            centerContentIfNeeded()
        }
        layoutBrushSizeIndicator()
    }

    private func configureContentViewAnchorForRetouchTransform() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        contentView.bounds = CGRect(origin: .zero, size: size)
        contentView.layer.anchorPoint = CGPoint(x: 0, y: 0)
        contentView.layer.position = .zero
    }

    private func restoreContentViewAnchorForScrollZoom() {
        contentView.transform = .identity
        contentView.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        contentView.frame = CGRect(origin: .zero, size: bounds.size)
    }

    func resetRetouchZoom() {
        resetZoomCanvas()
    }

    private func resetZoomCanvas() {
        // Clear custom transform before touching UIScrollView zoom APIs.
        contentView.transform = .identity
        retouchLiveScale = 1
        if !isRetouchDrawingEnabled {
            restoreContentViewAnchorForScrollZoom()
        }
        if abs(zoomScale - 1) > 0.001 {
            setZoomScale(1, animated: false)
        }
        contentOffset = .zero
        if isRetouchDrawingEnabled {
            configureContentViewAnchorForRetouchTransform()
            baseImageView.frame = contentView.bounds
            overlayImageView.frame = contentView.bounds
            contentSize = bounds.size
        } else {
            applyInitialZoomLayout()
        }
        onZoomScaleChanged?(1)
    }

    private func applyRetouchInteractionMode() {
        retouchPanGesture.isEnabled = isRetouchDrawingEnabled
        retouchTwoFingerTransformGesture.isEnabled = isRetouchDrawingEnabled

        if isRetouchDrawingEnabled {
            minimumZoomScale = 1
            maximumZoomScale = 6
            isScrollEnabled = false
            bouncesZoom = false
            bounces = false
            delaysContentTouches = false
            canCancelContentTouches = false
            pinchGestureRecognizer?.isEnabled = false
            panGestureRecognizer.isEnabled = false
            configureContentViewAnchorForRetouchTransform()
        } else {
            if retouchLiveScale > 1.01 {
                retouchLiveScale = 1
            }
            restoreContentViewAnchorForScrollZoom()
            minimumZoomScale = 1
            maximumZoomScale = 3
            isScrollEnabled = true
            bounces = true
            canCancelContentTouches = true
            pinchGestureRecognizer?.isEnabled = true
            panGestureRecognizer.isEnabled = true
            panGestureRecognizer.minimumNumberOfTouches = 1
            panGestureRecognizer.maximumNumberOfTouches = Int.max
            if zoomScale > maximumZoomScale {
                setZoomScale(maximumZoomScale, animated: false)
            }
        }
    }

    /// Flat composite preview (e.g. device frame mode).
    var image: UIImage? {
        get { baseImageView.image }
        set {
            usesLayeredPreview = false
            baseImageView.image = newValue
            overlayImageView.image = nil
            overlayImageView.isHidden = true
            resetWatermarkLiveAdjustments()
            resetZoomCanvas()
        }
    }

    func setLayeredPreview(base: UIImage, overlay: UIImage?) {
        usesLayeredPreview = overlay != nil
        baseImageView.image = base
        overlayImageView.image = overlay
        overlayImageView.isHidden = overlay == nil
        resetWatermarkLiveAdjustments()
        resetZoomCanvas()
    }

    func updateOverlayImage(_ overlay: UIImage) {
        usesLayeredPreview = true
        overlayImageView.image = overlay
        overlayImageView.isHidden = false
        overlayImageView.transform = .identity
    }

    func updatePreviewLayers(base: UIImage, overlay: UIImage) {
        usesLayeredPreview = true
        baseImageView.image = base
        overlayImageView.image = overlay
        overlayImageView.isHidden = false
        overlayImageView.transform = .identity
    }

    func applyWatermarkLiveAdjustments(
        opacity: CGFloat,
        scale: CGFloat,
        committedScale: CGFloat,
        mode: WatermarkMode,
        cornerPosition: CornerPosition
    ) {
        guard usesLayeredPreview else { return }

        overlayImageView.alpha = opacity
        let scaleFactor = committedScale > 0 ? scale / committedScale : 1

        switch mode {
        case .tiled:
            overlayImageView.transform = scaleFactor == 1
                ? .identity
                : CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)
        case .corner, .retouch:
            overlayImageView.transform = .identity
        case .card:
            break
        }
    }

    func resetWatermarkLiveAdjustments() {
        overlayImageView.alpha = 1
        overlayImageView.transform = .identity
    }

    func setRetouchDisplay(composite: UIImage, maskOverlay: UIImage?, referenceSize: CGSize) {
        retouchReferenceSize = referenceSize
        baseImageView.image = composite
        if let maskOverlay {
            usesLayeredPreview = true
            overlayImageView.image = maskOverlay
            overlayImageView.isHidden = false
            overlayImageView.alpha = 1
        } else {
            usesLayeredPreview = false
            overlayImageView.image = nil
            overlayImageView.isHidden = true
        }
    }

    /// Updates the retouch composite without resetting the current zoom level.
    func updateRetouchPreview(_ compositeImage: UIImage, referenceSize: CGSize) {
        retouchReferenceSize = referenceSize
        usesLayeredPreview = false
        baseImageView.image = compositeImage
        overlayImageView.image = nil
        overlayImageView.isHidden = true
    }

    func updateRetouchPreview(_ compositeImage: UIImage) {
        updateRetouchPreview(compositeImage, referenceSize: compositeImage.size)
    }

    /// Shows a circle at the visible card center matching brush diameter (image-space points).
    func showBrushSizeIndicator(diameter: CGFloat, color: UIColor) {
        brushIndicatorDiameterInImage = diameter
        brushSizeIndicatorView.backgroundColor = color
        brushSizeIndicatorView.isHidden = false
        bringSubviewToFront(brushSizeIndicatorView)
        layoutBrushSizeIndicator()
    }

    func updateBrushSizeIndicator(diameter: CGFloat, color: UIColor) {
        brushIndicatorDiameterInImage = diameter
        brushSizeIndicatorView.backgroundColor = color
        if brushSizeIndicatorView.isHidden {
            brushSizeIndicatorView.isHidden = false
            bringSubviewToFront(brushSizeIndicatorView)
        }
        layoutBrushSizeIndicator()
    }

    func hideBrushSizeIndicator() {
        brushSizeIndicatorView.isHidden = true
        brushIndicatorDiameterInImage = 0
    }

    private func displayedImageRect() -> CGRect? {
        let imageSize = retouchReferenceSize != .zero
            ? retouchReferenceSize
            : baseImageView.image?.size
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let viewSize = baseImageView.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }

        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let displayedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (viewSize.width - displayedSize.width) / 2,
            y: (viewSize.height - displayedSize.height) / 2,
            width: displayedSize.width,
            height: displayedSize.height
        )
    }

    private func layoutBrushSizeIndicator() {
        guard !brushSizeIndicatorView.isHidden,
              brushIndicatorDiameterInImage > 0,
              bounds.width > 0, bounds.height > 0,
              let imageRect = displayedImageRect(),
              let imageSize = (retouchReferenceSize != .zero
                               ? Optional(retouchReferenceSize)
                               : baseImageView.image?.size),
              imageSize.width > 0 else { return }

        // Size matches on-screen brush (image points × fit scale × current zoom).
        // Position stays at the card/viewport center, independent of photo transform.
        let displayScale = imageRect.width / imageSize.width
        let diameter = max(brushIndicatorDiameterInImage * displayScale * effectiveZoomScale, 4)
        brushSizeIndicatorView.bounds = CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter))
        brushSizeIndicatorView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        brushSizeIndicatorView.layer.cornerRadius = diameter / 2
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }

    /// Retouch mode uses transform-based zoom; other modes use scroll-view zoomScale.
    var effectiveZoomScale: CGFloat {
        isRetouchDrawingEnabled ? retouchLiveScale : zoomScale
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard !isRetouchDrawingEnabled else { return }
        if zoomScale <= 1.01 {
            centerContentIfNeeded()
        }
        onZoomScaleChanged?(zoomScale)
    }

    private func centerContentIfNeeded() {
        let boundsSize = bounds.size
        var frame = contentView.frame

        if frame.size.width < boundsSize.width {
            frame.origin.x = (boundsSize.width - frame.size.width) / 2
        } else {
            frame.origin.x = 0
        }

        if frame.size.height < boundsSize.height {
            frame.origin.y = (boundsSize.height - frame.size.height) / 2
        } else {
            frame.origin.y = 0
        }

        contentView.frame = frame
    }

    func imagePoint(from locationInImageView: CGPoint) -> CGPoint? {
        let imageSize = retouchReferenceSize != .zero
            ? retouchReferenceSize
            : baseImageView.image?.size
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let imageViewSize = baseImageView.bounds.size
        guard imageViewSize.width > 0, imageViewSize.height > 0 else { return nil }

        let scale = min(imageViewSize.width / imageSize.width, imageViewSize.height / imageSize.height)
        let displayedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: (imageViewSize.width - displayedSize.width) / 2,
            y: (imageViewSize.height - displayedSize.height) / 2
        )

        let x = (locationInImageView.x - origin.x) / scale
        let y = (locationInImageView.y - origin.y) / scale
        guard x >= 0, y >= 0, x <= imageSize.width, y <= imageSize.height else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func twoFingerGeometry(from gesture: UIPanGestureRecognizer) -> (midpoint: CGPoint, distance: CGFloat)? {
        guard gesture.numberOfTouches >= 2 else { return nil }
        let p0 = gesture.location(ofTouch: 0, in: self)
        let p1 = gesture.location(ofTouch: 1, in: self)
        let midpoint = CGPoint(x: (p0.x + p1.x) * 0.5, y: (p0.y + p1.y) * 0.5)
        let distance = max(hypot(p0.x - p1.x, p0.y - p1.y), 1)
        return (midpoint, distance)
    }

    /// Applies scale + pan via contentView.transform to avoid UIScrollView zoom jitter.
    /// Transform uses top-left anchor so the pinch midpoint stays fixed on screen.
    private func applyRetouchTwoFingerTransform(
        scale: CGFloat,
        midpoint: CGPoint,
        anchorContent: CGPoint
    ) {
        let clampedScale = min(max(scale, minimumZoomScale), maximumZoomScale)
        if clampedScale <= 1.01 {
            resetZoomCanvas()
            return
        }

        let tx = midpoint.x - anchorContent.x * clampedScale
        let ty = midpoint.y - anchorContent.y * clampedScale
        contentView.transform = CGAffineTransform(
            a: clampedScale, b: 0, c: 0, d: clampedScale, tx: tx, ty: ty
        )
        retouchLiveScale = clampedScale
    }

    private func contentPoint(forScrollViewPoint point: CGPoint) -> CGPoint {
        convert(point, to: contentView)
    }

    @objc private func handleRetouchTwoFingerTransform(_ gesture: UIPanGestureRecognizer) {
        guard isRetouchDrawingEnabled else { return }

        switch gesture.state {
        case .began:
            guard let geometry = twoFingerGeometry(from: gesture) else { return }
            isRetouchTwoFingerActive = true
            twoFingerInitialScale = retouchLiveScale
            twoFingerInitialAnchorContent = contentPoint(forScrollViewPoint: geometry.midpoint)
            twoFingerInitialDistance = geometry.distance
        case .changed:
            guard isRetouchTwoFingerActive,
                  let geometry = twoFingerGeometry(from: gesture),
                  twoFingerInitialDistance > 0 else { return }
            let newScale = twoFingerInitialScale * (geometry.distance / twoFingerInitialDistance)
            applyRetouchTwoFingerTransform(
                scale: newScale,
                midpoint: geometry.midpoint,
                anchorContent: twoFingerInitialAnchorContent
            )
            layoutBrushSizeIndicator()
        case .ended, .cancelled, .failed:
            isRetouchTwoFingerActive = false
            twoFingerInitialDistance = 0
            if retouchLiveScale <= 1.01 {
                resetZoomCanvas()
            } else {
                onZoomScaleChanged?(retouchLiveScale)
            }
        default:
            break
        }
    }

    @objc private func handleRetouchPan(_ gesture: UIPanGestureRecognizer) {
        guard isRetouchDrawingEnabled, !isRetouchTwoFingerActive else { return }

        let location = gesture.location(in: baseImageView)
        guard let imagePoint = imagePoint(from: location) else {
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                if retouchDidMove || retouchLastPoint != nil {
                    retouchDelegate?.zoomableImageViewDidEndStroke(self)
                }
                retouchLastPoint = nil
                retouchDidMove = false
            }
            return
        }

        switch gesture.state {
        case .began:
            retouchLastPoint = imagePoint
            retouchDidMove = false
            retouchDelegate?.zoomableImageView(self, didBeginStrokeAt: imagePoint)
        case .changed:
            let start = retouchLastPoint ?? imagePoint
            guard hypot(imagePoint.x - start.x, imagePoint.y - start.y) >= 1 else { return }
            retouchDidMove = true
            retouchDelegate?.zoomableImageView(self, didStrokeFrom: start, to: imagePoint)
            retouchLastPoint = imagePoint
        case .ended, .cancelled, .failed:
            if !retouchDidMove {
                let point = retouchLastPoint ?? imagePoint
                retouchDelegate?.zoomableImageView(self, didStrokeFrom: point, to: point)
            }
            retouchDelegate?.zoomableImageViewDidEndStroke(self)
            retouchLastPoint = nil
            retouchDidMove = false
        default:
            break
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === retouchTwoFingerTransformGesture
            || otherGestureRecognizer === retouchTwoFingerTransformGesture {
            return true
        }
        let isPinch = gestureRecognizer === pinchGestureRecognizer
            || otherGestureRecognizer === pinchGestureRecognizer
        let isScrollPan = gestureRecognizer === panGestureRecognizer
            || otherGestureRecognizer === panGestureRecognizer
        if isPinch || isScrollPan {
            return true
        }
        if gestureRecognizer === retouchPanGesture || otherGestureRecognizer === retouchPanGesture {
            return true
        }
        return false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        if gestureRecognizer === retouchPanGesture {
            return isRetouchDrawingEnabled && !isRetouchTwoFingerActive
        }
        if gestureRecognizer === retouchTwoFingerTransformGesture {
            return isRetouchDrawingEnabled
        }
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === retouchPanGesture {
            return isRetouchDrawingEnabled
                && !isRetouchTwoFingerActive
                && gestureRecognizer.numberOfTouches <= 1
        }
        if gestureRecognizer === retouchTwoFingerTransformGesture {
            return isRetouchDrawingEnabled
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
