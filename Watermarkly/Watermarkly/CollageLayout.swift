import UIKit
import CoreImage
import Vision

// MARK: - Options

enum CollageBackgroundStyle: Int, CaseIterable {
    case white
    case lightGray
    case blurred

    var title: String {
        switch self {
        case .white: return L10n.collageBgWhite
        case .lightGray: return L10n.collageBgGray
        case .blurred: return L10n.collageBgBlur
        }
    }

    var solidColor: UIColor? {
        switch self {
        case .white: return .white
        case .lightGray: return UIColor(white: 0.94, alpha: 1)
        case .blurred: return nil
        }
    }
}

enum CollageLayoutType: Int, CaseIterable {
    case grid3x3
    case portrait4x5
    case portrait9x16

    var title: String {
        switch self {
        case .grid3x3: return L10n.layoutGrid3x3
        case .portrait4x5: return L10n.layoutPortrait4x5
        case .portrait9x16: return L10n.layoutPortrait9x16
        }
    }

    var canvasSize: CGSize {
        switch self {
        case .grid3x3: return CGSize(width: 3000, height: 3000)
        case .portrait4x5: return CGSize(width: 3000, height: 3750)
        case .portrait9x16: return CGSize(width: 1688, height: 3000)
        }
    }

    var columnCount: Int {
        switch self {
        case .grid3x3: return 3
        case .portrait4x5: return 2
        case .portrait9x16: return 3
        }
    }

    var supportsHeroLayout: Bool {
        switch self {
        case .grid3x3, .portrait4x5: return true
        case .portrait9x16: return false
        }
    }

    var baseSpacing: CGFloat { 5 }
    var minSpacing: CGFloat { 2 }
}

struct CollageCellAdjustment: Equatable {
    /// Zoom multiplier applied on top of the default fill/fit baseline (minimum 1).
    var scale: CGFloat = 1
    /// Pan offset in preview/canvas points relative to the cell center.
    var offset: CGPoint = .zero
}

struct CollageLayoutOptions {
    var layoutType: CollageLayoutType = .grid3x3
    var backgroundStyle: CollageBackgroundStyle = .white
    var heroLayout: Bool = false
    var cellPadColor: UIColor = .white
    /// Preferred gap between cells, in canvas points. Default matches the current layout spacing.
    var spacing: CGFloat = CollageLayoutType.grid3x3.baseSpacing
    var cellAdjustments: [Int: CollageCellAdjustment] = [:]
}

struct CollageLayoutSlot: Equatable {
    let slotIndex: Int
    let rect: CGRect
    let imageIndex: Int
}

struct CollageComputedLayout: Equatable {
    let canvasSize: CGSize
    let spacing: CGFloat
    let slots: [CollageLayoutSlot]
}

// MARK: - Engine

enum CollageLayoutEngine {

    private struct GridCell: Hashable {
        let column: Int
        let row: Int
    }

    private struct Slot {
        let slotIndex: Int
        let rect: CGRect
        let imageIndex: Int
    }

    private struct SubjectFocus {
        var center: CGPoint
        var hasSubject: Bool
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func computeLayout(imageCount: Int, options: CollageLayoutOptions) -> CollageComputedLayout {
        let layoutType = options.layoutType
        let canvasSize = layoutType.canvasSize
        let hero = options.heroLayout && layoutType.supportsHeroLayout
        let spacing = resolvedSpacing(
            imageCount: imageCount,
            layoutType: layoutType,
            heroLayout: hero,
            canvasSize: canvasSize,
            preferredSpacing: options.spacing
        )
        let slots = buildSlots(
            imageCount: imageCount,
            layoutType: layoutType,
            canvasSize: canvasSize,
            spacing: spacing,
            heroLayout: hero
        ).map {
            CollageLayoutSlot(slotIndex: $0.slotIndex, rect: $0.rect, imageIndex: $0.imageIndex)
        }
        return CollageComputedLayout(canvasSize: canvasSize, spacing: spacing, slots: slots)
    }

    static func layoutImages(_ images: [UIImage], options: CollageLayoutOptions) -> UIImage? {
        guard !images.isEmpty else { return nil }

        let layout = computeLayout(imageCount: images.count, options: options)
        let canvasSize = layout.canvasSize
        let focusMap = buildSubjectFocusMap(for: images)

        return ImageLoader.renderOpaque(size: canvasSize, scale: 1) { context in
            drawCanvasBackground(
                images: images,
                style: options.backgroundStyle,
                canvasSize: canvasSize,
                context: context
            )

            for slot in layout.slots where slot.imageIndex < images.count {
                let adjustment = options.cellAdjustments[slot.slotIndex] ?? CollageCellAdjustment()
                drawImage(
                    images[slot.imageIndex],
                    in: slot.rect,
                    adjustment: adjustment,
                    padColor: options.cellPadColor,
                    focus: focusMap[slot.imageIndex] ?? SubjectFocus(center: CGPoint(x: 0.5, y: 0.5), hasSubject: false),
                    context: context
                )
            }
        }
    }

    // MARK: - Spacing & slots

    private static func resolvedSpacing(
        imageCount: Int,
        layoutType: CollageLayoutType,
        heroLayout: Bool,
        canvasSize: CGSize,
        preferredSpacing: CGFloat
    ) -> CGFloat {
        var spacing = max(0, preferredSpacing)
        while spacing >= 0 {
            let slots = buildSlots(
                imageCount: imageCount,
                layoutType: layoutType,
                canvasSize: canvasSize,
                spacing: spacing,
                heroLayout: heroLayout
            )
            if gridFits(slots: slots, canvasSize: canvasSize) {
                return spacing
            }
            spacing -= 1
        }
        return 0
    }

    private static func gridFits(slots: [Slot], canvasSize: CGSize) -> Bool {
        guard let maxY = slots.map({ $0.rect.maxY }).max() else { return true }
        return maxY <= canvasSize.height + 0.5
    }

    private static func buildSlots(
        imageCount: Int,
        layoutType: CollageLayoutType,
        canvasSize: CGSize,
        spacing: CGFloat,
        heroLayout: Bool
    ) -> [Slot] {
        switch layoutType {
        case .grid3x3:
            return buildSquareGridSlots(
                imageCount: imageCount,
                columns: 3,
                rows: 3,
                canvasSize: canvasSize,
                spacing: spacing,
                heroLayout: heroLayout
            )
        case .portrait4x5:
            // 1 photo: fill the whole 4:5 canvas.
            if imageCount == 1 {
                return buildFullBleedSlots(imageCount: 1, canvasSize: canvasSize, spacing: spacing)
            }
            return buildPortraitGridSlots(
                imageCount: imageCount,
                columns: 2,
                canvasSize: canvasSize,
                spacing: spacing,
                heroLayout: heroLayout
            )
        case .portrait9x16:
            // 1 photo fills all; 2 photos stack and each fills half of the canvas.
            if imageCount <= 2 {
                return buildFullBleedSlots(imageCount: imageCount, canvasSize: canvasSize, spacing: spacing)
            }
            return buildPortraitGridSlots(
                imageCount: imageCount,
                columns: 3,
                canvasSize: canvasSize,
                spacing: spacing,
                heroLayout: false
            )
        }
    }

    /// One or two photos stretched to fill the canvas (full-bleed with optional outer/gap spacing).
    private static func buildFullBleedSlots(
        imageCount: Int,
        canvasSize: CGSize,
        spacing: CGFloat
    ) -> [Slot] {
        guard imageCount > 0 else { return [] }
        let inset = max(0, spacing)
        let contentWidth = max(1, canvasSize.width - inset * 2)

        if imageCount == 1 {
            let rect = CGRect(
                x: inset,
                y: inset,
                width: contentWidth,
                height: max(1, canvasSize.height - inset * 2)
            )
            return [Slot(slotIndex: 0, rect: rect, imageIndex: 0)]
        }

        let gap = inset
        let cellHeight = max(1, (canvasSize.height - inset * 2 - gap) / 2)
        return (0..<2).map { index in
            let rect = CGRect(
                x: inset,
                y: inset + CGFloat(index) * (cellHeight + gap),
                width: contentWidth,
                height: cellHeight
            )
            return Slot(slotIndex: index, rect: rect, imageIndex: index)
        }
    }

    private static func buildSquareGridSlots(
        imageCount: Int,
        columns: Int,
        rows: Int,
        canvasSize: CGSize,
        spacing: CGFloat,
        heroLayout: Bool
    ) -> [Slot] {
        let cellWidth = (canvasSize.width - spacing * CGFloat(columns + 1)) / CGFloat(columns)
        let cellHeight = (canvasSize.height - spacing * CGFloat(rows + 1)) / CGFloat(rows)
        var occupied = Set<GridCell>()
        var slots: [Slot] = []

        func rectForCells(_ cells: [GridCell]) -> CGRect {
            let cols = cells.map(\.column)
            let rowValues = cells.map(\.row)
            let minCol = cols.min() ?? 0
            let maxCol = cols.max() ?? 0
            let minRow = rowValues.min() ?? 0
            let maxRow = rowValues.max() ?? 0
            return CGRect(
                x: spacing + CGFloat(minCol) * (cellWidth + spacing),
                y: spacing + CGFloat(minRow) * (cellHeight + spacing),
                width: CGFloat(maxCol - minCol + 1) * cellWidth + CGFloat(maxCol - minCol) * spacing,
                height: CGFloat(maxRow - minRow + 1) * cellHeight + CGFloat(maxRow - minRow) * spacing
            )
        }

        var nextIndex = 0
        if heroLayout, imageCount > 0 {
            let heroCells = [GridCell(column: 0, row: 0), GridCell(column: 1, row: 0)]
            heroCells.forEach { occupied.insert($0) }
            slots.append(Slot(slotIndex: slots.count, rect: rectForCells(heroCells), imageIndex: 0))
            nextIndex = 1
        }

        for row in 0..<rows {
            for col in 0..<columns {
                let cell = GridCell(column: col, row: row)
                guard !occupied.contains(cell), nextIndex < imageCount else { continue }
                occupied.insert(cell)
                slots.append(Slot(slotIndex: slots.count, rect: rectForCells([cell]), imageIndex: nextIndex))
                nextIndex += 1
            }
        }
        return slots
    }

    private static func buildPortraitGridSlots(
        imageCount: Int,
        columns: Int,
        canvasSize: CGSize,
        spacing: CGFloat,
        heroLayout: Bool
    ) -> [Slot] {
        guard imageCount > 0 else { return [] }

        let cellWidth = (canvasSize.width - spacing * CGFloat(columns + 1)) / CGFloat(columns)
        var slots: [Slot] = []
        var nextIndex = 0
        var currentY = spacing

        if heroLayout {
            let heroHeight = cellWidth * 0.82
            let heroRect = CGRect(
                x: spacing,
                y: currentY,
                width: canvasSize.width - spacing * 2,
                height: heroHeight
            )
            slots.append(Slot(slotIndex: slots.count, rect: heroRect, imageIndex: 0))
            nextIndex = 1
            currentY = heroRect.maxY + spacing
        }

        let remaining = max(0, imageCount - nextIndex)
        let rows = Int(ceil(Double(remaining) / Double(columns)))
        guard rows > 0 else { return slots }

        let availableHeight = canvasSize.height - currentY - spacing
        let cellHeight = max(
            120,
            (availableHeight - spacing * CGFloat(max(rows - 1, 0))) / CGFloat(rows)
        )

        for row in 0..<rows {
            for col in 0..<columns {
                guard nextIndex < imageCount else { return slots }
                let rect = CGRect(
                    x: spacing + CGFloat(col) * (cellWidth + spacing),
                    y: currentY + CGFloat(row) * (cellHeight + spacing),
                    width: cellWidth,
                    height: cellHeight
                )
                slots.append(Slot(slotIndex: slots.count, rect: rect, imageIndex: nextIndex))
                nextIndex += 1
            }
        }
        return slots
    }

    // MARK: - Background

    static func previewBlurredBackground(from image: UIImage, size: CGSize) -> UIImage? {
        let canvas = CGSize(width: max(size.width, 320), height: max(size.height, 320))
        return makeBlurredBackgroundImage(from: image, canvasSize: canvas)
    }

    private static func drawCanvasBackground(
        images: [UIImage],
        style: CollageBackgroundStyle,
        canvasSize: CGSize,
        context: CGContext
    ) {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)

        if let solid = style.solidColor {
            context.setFillColor(solid.cgColor)
            context.fill(canvasRect)
            return
        }

        context.setFillColor(UIColor.white.cgColor)
        context.fill(canvasRect)

        guard let source = images.first else { return }
        guard let blurred = makeBlurredBackgroundImage(from: source, canvasSize: canvasSize) else { return }

        UIGraphicsPushContext(context)
        blurred.draw(in: canvasRect, blendMode: .normal, alpha: 0.3)
        UIGraphicsPopContext()
    }

    private static func makeBlurredBackgroundImage(from image: UIImage, canvasSize: CGSize) -> UIImage? {
        let normalized = ImageLoader.normalized(image)
        guard let cgImage = normalized.cgImage else { return nil }

        var ciImage = CIImage(cgImage: cgImage)
        let imageSize = ciImage.extent.size
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let scale = max(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
        ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let scaledExtent = ciImage.extent
        let cropX = scaledExtent.midX - canvasSize.width / 2
        let cropY = scaledExtent.midY - canvasSize.height / 2
        ciImage = ciImage.cropped(to: CGRect(x: cropX, y: cropY, width: canvasSize.width, height: canvasSize.height))

        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(ciImage, forKey: kCIInputImageKey)
        blur.setValue(28, forKey: kCIInputRadiusKey)
        guard let blurred = blur.outputImage else { return nil }

        let cropped = blurred.cropped(to: CGRect(origin: .zero, size: canvasSize))
        guard let output = ciContext.createCGImage(cropped, from: cropped.extent) else { return nil }
        return UIImage(cgImage: output, scale: 1, orientation: .up)
    }

    // MARK: - Cell drawing

    /// Adaptive cover: scale just enough to fill the cell (no letterbox), without
    /// treating image pixels as view points (which over-zoomed small cells).
    private static func drawImage(
        _ image: UIImage,
        in rect: CGRect,
        adjustment: CollageCellAdjustment,
        padColor: UIColor,
        focus: SubjectFocus,
        context: CGContext
    ) {
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(padColor.cgColor)
        context.fill(rect)

        if let rendered = renderCoveredCell(
            image: image,
            targetSize: rect.size,
            focus: focus,
            adjustment: adjustment,
            padColor: padColor
        ) {
            UIGraphicsPushContext(context)
            rendered.draw(in: rect)
            UIGraphicsPopContext()
        }

        context.restoreGState()
    }

    /// Frame used by the interactive preview image view inside a cell.
    static func drawFrame(
        for image: UIImage,
        in rect: CGRect,
        adjustment: CollageCellAdjustment
    ) -> CGRect {
        let normalized = ImageLoader.normalized(image)
        let imageSize = normalized.size
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        return coverFrame(imageSize: imageSize, in: rect, focus: nil, adjustment: adjustment)
    }

    /// Minimum scale that fully covers `rect`, then optional user pinch (`adjustment.scale` ≥ 1).
    /// When `focus` is set, pan the covered image so the subject stays centered before clamping.
    private static func coverFrame(
        imageSize: CGSize,
        in rect: CGRect,
        focus: SubjectFocus?,
        adjustment: CollageCellAdjustment
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              rect.width > 0, rect.height > 0 else { return rect }

        let coverScale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let scale = coverScale * max(adjustment.scale, 1)
        let width = imageSize.width * scale
        let height = imageSize.height * scale

        var center = CGPoint(x: rect.midX, y: rect.midY)
        if let focus, focus.hasSubject, adjustment.scale <= 1.001, adjustment.offset == .zero {
            // Shift so subject focus maps near the cell center, without extra zoom.
            let focusInImage = CGPoint(x: focus.center.x * imageSize.width, y: focus.center.y * imageSize.height)
            let focusOnCanvas = CGPoint(
                x: rect.midX - width / 2 + focusInImage.x * scale,
                y: rect.midY - height / 2 + focusInImage.y * scale
            )
            center.x += rect.midX - focusOnCanvas.x
            center.y += rect.midY - focusOnCanvas.y
        }

        var origin = CGPoint(
            x: center.x - width / 2 + adjustment.offset.x,
            y: center.y - height / 2 + adjustment.offset.y
        )
        origin.x = min(rect.minX, max(origin.x, rect.maxX - width))
        origin.y = min(rect.minY, max(origin.y, rect.maxY - height))
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    private static func renderCoveredCell(
        image: UIImage,
        targetSize: CGSize,
        focus: SubjectFocus,
        adjustment: CollageCellAdjustment,
        padColor: UIColor
    ) -> UIImage? {
        let normalized = ImageLoader.normalized(image)
        let targetRect = CGRect(origin: .zero, size: targetSize)
        let drawRect = coverFrame(
            imageSize: normalized.size,
            in: targetRect,
            focus: focus,
            adjustment: adjustment
        )
        return ImageLoader.renderOpaque(size: targetSize, scale: 1) { context in
            context.setFillColor(padColor.cgColor)
            context.fill(targetRect)
            UIGraphicsPushContext(context)
            normalized.draw(in: drawRect)
            UIGraphicsPopContext()
        }
    }

    // MARK: - Vision subject focus

    private static func buildSubjectFocusMap(for images: [UIImage]) -> [Int: SubjectFocus] {
        var map: [Int: SubjectFocus] = [:]
        for (index, image) in images.enumerated() {
            map[index] = detectSubjectFocus(in: image)
        }
        return map
    }

    private static func detectSubjectFocus(in image: UIImage) -> SubjectFocus {
        let normalized = ImageLoader.normalized(image)
        guard let cgImage = normalized.cgImage else {
            return SubjectFocus(center: CGPoint(x: 0.5, y: 0.5), hasSubject: false)
        }

        if #available(iOS 17.0, *) {
            if let maskFocus = subjectFocusFromInstanceMask(cgImage: cgImage, imageSize: normalized.size) {
                return maskFocus
            }
        }

        if let faceFocus = subjectFocusFromFaces(cgImage: cgImage, imageSize: normalized.size) {
            return faceFocus
        }

        return SubjectFocus(center: CGPoint(x: 0.5, y: 0.5), hasSubject: false)
    }

    @available(iOS 17.0, *)
    private static func subjectFocusFromInstanceMask(cgImage: CGImage, imageSize: CGSize) -> SubjectFocus? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return nil }

        let instances = observation.allInstances
        guard !instances.isEmpty,
              let maskBuffer = try? observation.generateScaledMaskForImage(forInstances: instances, from: handler)
        else { return nil }

        CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(maskBuffer)
        let height = CVPixelBufferGetHeight(maskBuffer)
        guard width > 0, height > 0,
              let base = CVPixelBufferGetBaseAddress(maskBuffer) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
        var minX = width, maxX = 0, minY = height, maxY = 0
        var found = false

        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width where row[x] > 32 {
                found = true
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }

        guard found, maxX >= minX, maxY >= minY else { return nil }

        let centerX = (CGFloat(minX) + CGFloat(maxX) + 1) / 2 / CGFloat(width)
        let centerY = (CGFloat(minY) + CGFloat(maxY) + 1) / 2 / CGFloat(height)
        return SubjectFocus(center: CGPoint(x: centerX, y: centerY), hasSubject: true)
    }

    private static func subjectFocusFromFaces(cgImage: CGImage, imageSize: CGSize) -> SubjectFocus? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let faces = request.results, !faces.isEmpty else { return nil }

        var union = faces[0].boundingBox
        for face in faces.dropFirst() {
            union = union.union(face.boundingBox)
        }

        // Vision bounding boxes are normalized with origin bottom-left.
        let centerX = union.midX
        let centerY = 1 - union.midY
        return SubjectFocus(center: CGPoint(x: centerX, y: centerY), hasSubject: true)
    }
}
