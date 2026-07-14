import UIKit

protocol EditPhotoPagerViewDataSource: AnyObject {
    func photoPager(_ pager: EditPhotoPagerView, configure cell: EditPhotoPagerCell, at index: Int)
}

protocol EditPhotoPagerViewDelegate: AnyObject {
    func photoPager(_ pager: EditPhotoPagerView, didScrollToPage index: Int)
}

/// Collection view that stops intercepting gestures when horizontal paging is disabled (Retouch mode).
private final class EditPhotoCollectionView: UICollectionView {

    var allowsHorizontalPaging = true

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if !allowsHorizontalPaging, gestureRecognizer === panGestureRecognizer {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if otherGestureRecognizer.view is ZoomableImageView {
            return true
        }
        return false
    }
}

/// Horizontal paging preview for multi-photo edit sessions.
final class EditPhotoPagerView: UIView {

    weak var dataSource: EditPhotoPagerViewDataSource?
    weak var delegate: EditPhotoPagerViewDelegate?

    private(set) var currentPage = 0
    private var imageCount = 1
    private var lastLayoutBounds: CGSize = .zero
    /// When false (e.g. Retouch mode), horizontal page swipes stay disabled even after zooming out.
    private var allowsPaging = true
    private var restorePagingDisabledAfterAnimation = false

    private lazy var collectionView: EditPhotoCollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        let collection = EditPhotoCollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.isPagingEnabled = true
        collection.showsHorizontalScrollIndicator = false
        collection.alwaysBounceHorizontal = false
        collection.decelerationRate = .fast
        collection.delaysContentTouches = false
        collection.canCancelContentTouches = false
        collection.isMultipleTouchEnabled = true
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.register(EditPhotoPagerCell.self, forCellWithReuseIdentifier: EditPhotoPagerCell.reuseID)
        collection.dataSource = self
        collection.delegate = self
        return collection
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastLayoutBounds else { return }
        lastLayoutBounds = bounds.size
        collectionView.collectionViewLayout.invalidateLayout()
    }

    func configure(imageCount: Int, initialPage: Int = 0) {
        self.imageCount = max(imageCount, 1)
        currentPage = min(max(initialPage, 0), self.imageCount - 1)
        updateCollectionScrollEnabled(forZoomScale: 1)
        collectionView.reloadData()
        layoutIfNeeded()
        scrollToPage(currentPage, animated: false)
    }

    func cell(at index: Int) -> EditPhotoPagerCell? {
        let indexPath = IndexPath(item: index, section: 0)
        return collectionView.cellForItem(at: indexPath) as? EditPhotoPagerCell
    }

    func previewView(at index: Int) -> ZoomableImageView? {
        cell(at: index)?.zoomablePreview
    }

    func visiblePreviewView() -> ZoomableImageView? {
        previewView(at: currentPage)
    }

    func scrollToPage(_ index: Int, animated: Bool) {
        guard imageCount > 0 else { return }
        let clamped = min(max(index, 0), imageCount - 1)
        currentPage = clamped
        collectionView.layoutIfNeeded()

        guard collectionView.bounds.width > 1,
              collectionView.numberOfItems(inSection: 0) > clamped else {
            DispatchQueue.main.async { [weak self] in
                self?.scrollToPage(clamped, animated: false)
            }
            return
        }

        // Programmatic jumps must temporarily allow scrolling when swipe-paging is disabled
        // (Retouch). Calling setContentOffset while isScrollEnabled == false is flaky.
        let pagingLocked = !allowsPaging
        if pagingLocked {
            collectionView.isScrollEnabled = true
            collectionView.panGestureRecognizer.isEnabled = false
        }

        let indexPath = IndexPath(item: clamped, section: 0)
        collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: animated)

        if pagingLocked {
            if animated {
                restorePagingDisabledAfterAnimation = true
            } else {
                collectionView.layoutIfNeeded()
                updateCollectionScrollEnabled(forZoomScale: visiblePreviewView()?.effectiveZoomScale ?? 1)
            }
        }
    }

    var isPagingEnabled: Bool {
        get { allowsPaging && collectionView.isScrollEnabled }
        set {
            allowsPaging = newValue
            collectionView.allowsHorizontalPaging = newValue
            collectionView.delaysContentTouches = newValue
            updateCollectionScrollEnabled(forZoomScale: visiblePreviewView()?.effectiveZoomScale ?? 1)
        }
    }

    private func updateCollectionScrollEnabled(forZoomScale scale: CGFloat) {
        let enablePaging = allowsPaging && imageCount > 1 && scale <= 1.01
        collectionView.isScrollEnabled = enablePaging
        collectionView.isPagingEnabled = enablePaging
        collectionView.allowsHorizontalPaging = enablePaging
        collectionView.panGestureRecognizer.isEnabled = enablePaging
        collectionView.alwaysBounceHorizontal = enablePaging
    }

    private func pageIndex(for scrollView: UIScrollView) -> Int {
        let width = max(scrollView.bounds.width, 1)
        return Int(round(scrollView.contentOffset.x / width))
    }

    private func bindZoomHandler(for cell: EditPhotoPagerCell) {
        cell.zoomablePreview.onZoomScaleChanged = { [weak self] scale in
            self?.updateCollectionScrollEnabled(forZoomScale: scale)
        }
    }
}
// MARK: - Collection

extension EditPhotoPagerView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        imageCount
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: EditPhotoPagerCell.reuseID,
            for: indexPath
        ) as! EditPhotoPagerCell
        bindZoomHandler(for: cell)
        dataSource?.photoPager(self, configure: cell, at: indexPath.item)
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        collectionView.bounds.size
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishProgrammaticScrollIfNeeded()
        let page = pageIndex(for: scrollView)
        guard page != currentPage, page >= 0, page < imageCount else { return }
        currentPage = page
        delegate?.photoPager(self, didScrollToPage: page)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            finishProgrammaticScrollIfNeeded()
            let page = pageIndex(for: scrollView)
            guard page != currentPage, page >= 0, page < imageCount else { return }
            currentPage = page
            delegate?.photoPager(self, didScrollToPage: page)
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        finishProgrammaticScrollIfNeeded()
    }

    private func finishProgrammaticScrollIfNeeded() {
        guard restorePagingDisabledAfterAnimation else { return }
        restorePagingDisabledAfterAnimation = false
        updateCollectionScrollEnabled(forZoomScale: visiblePreviewView()?.effectiveZoomScale ?? 1)
    }
}

// MARK: - Cell

final class EditPhotoPagerCell: UICollectionViewCell {
    static let reuseID = "EditPhotoPagerCell"

    private(set) var photoIndex = -1
    let zoomablePreview = ZoomableImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        isMultipleTouchEnabled = true
        contentView.isMultipleTouchEnabled = true
        zoomablePreview.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(zoomablePreview)
        NSLayoutConstraint.activate([
            zoomablePreview.topAnchor.constraint(equalTo: contentView.topAnchor),
            zoomablePreview.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            zoomablePreview.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            zoomablePreview.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        photoIndex = -1
        zoomablePreview.onZoomScaleChanged = nil
        zoomablePreview.retouchDelegate = nil
        // Disable retouch first so transform/anchor are restored before any zoom reset.
        zoomablePreview.isRetouchDrawingEnabled = false
        zoomablePreview.hideBrushSizeIndicator()
        zoomablePreview.resetRetouchZoom()
        zoomablePreview.resetWatermarkLiveAdjustments()
        zoomablePreview.image = nil
    }

    func prepareForPhoto(at index: Int) {
        let indexChanged = photoIndex != index
        photoIndex = index
        if indexChanged {
            zoomablePreview.resetRetouchZoom()
        }
        zoomablePreview.resetWatermarkLiveAdjustments()
    }
}
