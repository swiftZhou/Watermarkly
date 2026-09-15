import UIKit
import CoreImage
import Vision

enum CutoutError: LocalizedError {
    case invalidImage
    case unavailable
    case noSubjectFound
    case visionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage: return L10n.cutoutInvalidImage
        case .unavailable: return L10n.cutoutUnavailable
        case .noSubjectFound: return L10n.cutoutNoSubject
        case .visionFailed(let message): return message
        }
    }
}

enum WatermarkEngine {

    // MARK: - Public API

    static func applyWatermark(to image: UIImage, settings: WatermarkSettings) -> UIImage {
        guard isValidImage(image) else { return image }
        return autoreleasepool {
            switch settings.mode {
            case .tiled:
                return drawTiledWatermark(on: image, settings: settings)
            case .corner:
                return drawCornerWatermark(on: image, settings: settings)
            case .card:
                return applyPhotoFrame(to: image, settings: settings)
            case .cutout:
                return ImageLoader.normalized(image)
            case .retouch:
                return applyRetouch(to: image, normalizedStrokes: [], brushDiameter: settings.retouchBrushSize)
            }
        }
    }

    /// Watermark-only layer for live slider preview (no photo). Tiled overlays are rendered at
    /// rotation 0; live rotation uses an absolute UIView transform so drag preview matches export.
    static func renderWatermarkOverlay(for image: UIImage, settings: WatermarkSettings) -> UIImage? {
        guard isValidImage(image) else { return nil }
        let source = ImageLoader.normalized(image)

        var overlaySettings = settings
        overlaySettings.opacity = 1.0

        return autoreleasepool {
            switch settings.mode {
            case .tiled:
                return drawTiledWatermark(
                    on: source,
                    settings: overlaySettings,
                    drawBase: false,
                    layoutRotation: settings.rotation,
                    tileRotation: settings.rotation
                )
            case .corner:
                return drawCornerWatermark(on: source, settings: overlaySettings, drawBase: false)
            case .card:
                return nil
            case .cutout:
                return nil
            case .retouch:
                return nil
            }
        }
    }

    private static func isValidImage(_ image: UIImage) -> Bool {
        image.size.width > 0 && image.size.height > 0 && image.cgImage != nil
    }

    // MARK: - Tiled

    static func drawTiledWatermark(
        on image: UIImage,
        settings: WatermarkSettings,
        drawBase: Bool = true,
        layoutRotation: CGFloat? = nil,
        tileRotation: CGFloat? = nil
    ) -> UIImage {
        let source = ImageLoader.normalized(image)
        let size = source.size
        let scale = source.scale
        let gridRotation = layoutRotation ?? settings.rotation
        let perTileRotation = tileRotation ?? settings.rotation

        let render: (CGContext) -> Void = { context in
            if drawBase {
                source.draw(in: CGRect(origin: .zero, size: size))
            }

            let watermarkContent = watermarkContent(for: settings)
            guard let content = watermarkContent else { return }

            let fontSize = settings.fontSize * settings.tiledScale
            let attrs = textAttributes(fontSize: fontSize, opacity: settings.opacity)
            let contentSize = contentSize(
                for: content,
                attributes: attrs,
                canvasSize: size,
                settings: settings
            )

            let gridRadians = gridRotation * .pi / 180
            let tileRadians = perTileRotation * .pi / 180
            let cosR = cos(gridRadians)
            let sinR = sin(gridRadians)

            let stepU = max(contentSize.width + settings.spacing, 1)
            let stepV = max(contentSize.height + settings.spacing, 1)
            let rotatedSize = rotatedBoundingSize(for: contentSize, radians: tileRadians)
            let padding = max(rotatedSize.width, rotatedSize.height) / 2
            let extents = tiledGridExtents(
                canvasSize: size,
                cosR: cosR,
                sinR: sinR,
                padding: padding
            )

            let centerX = size.width / 2
            let centerY = size.height / 2
            var row = 0
            var v = extents.minV
            while v <= extents.maxV {
                var u = extents.minU
                if row % 2 != 0 {
                    u += stepU / 2
                }
                while u <= extents.maxU {
                    let tileCenterX = centerX + u * cosR - v * sinR
                    let tileCenterY = centerY + u * sinR + v * cosR

                    context.saveGState()
                    context.translateBy(x: tileCenterX, y: tileCenterY)
                    context.rotate(by: tileRadians)
                    drawWatermarkContent(
                        content,
                        in: CGRect(
                            x: -contentSize.width / 2,
                            y: -contentSize.height / 2,
                            width: contentSize.width,
                            height: contentSize.height
                        ),
                        attributes: attrs,
                        context: context
                    )
                    context.restoreGState()

                    u += stepU
                }
                v += stepV
                row += 1
            }
        }

        if drawBase {
            return ImageLoader.renderOpaque(size: size, scale: scale, draw: render) ?? source
        }
        return ImageLoader.renderTransparent(size: size, scale: scale, draw: render) ?? source
    }

    // MARK: - Corner

    static func drawCornerWatermark(on image: UIImage, settings: WatermarkSettings, drawBase: Bool = true) -> UIImage {
        let source = ImageLoader.normalized(image)
        let size = source.size
        let scale = source.scale

        let render: (CGContext) -> Void = { context in
            if drawBase {
                source.draw(in: CGRect(origin: .zero, size: size))
            }

            let watermarkContent = watermarkContent(for: settings)
            guard let content = watermarkContent else { return }

            let baseFontSize = max(12, size.width * 0.04)
            let fontSize = baseFontSize * (settings.cornerScale / 0.15)
            let attrs = textAttributes(fontSize: fontSize, opacity: settings.opacity)
            let contentSize = contentSize(
                for: content,
                attributes: attrs,
                canvasSize: size,
                settings: settings
            )
            let origin = cornerOrigin(
                for: settings.cornerPosition,
                contentSize: contentSize,
                imageSize: size,
                padding: settings.cornerPadding
            )

            drawWatermarkContent(
                content,
                in: CGRect(origin: origin, size: contentSize),
                attributes: attrs,
                context: context
            )
        }

        if drawBase {
            return ImageLoader.renderOpaque(size: size, scale: scale, draw: render) ?? source
        }
        return ImageLoader.renderTransparent(size: size, scale: scale, draw: render) ?? source
    }

    // MARK: - Photo Frame

    static func applyPhotoFrame(
        to image: UIImage,
        settings: WatermarkSettings
    ) -> UIImage {
        let caption: String?
        if settings.frameShowsCaption {
            let trimmed = settings.text.trimmingCharacters(in: .whitespacesAndNewlines)
            caption = trimmed.isEmpty ? nil : trimmed
        } else {
            caption = nil
        }

        return applyPhotoFrame(
            to: image,
            borderPercent: settings.frameBorderPercent,
            showsCaption: settings.frameShowsCaption,
            caption: caption
        )
    }

    /// Fixed shadow spread as a fraction of √(photo width × height). Does not scale with border.
    private static let frameShadowSpreadFactor: CGFloat = 0.058

    private struct PhotoFramePaddings {
        let horizontal: CGFloat
        let top: CGFloat
        let bottom: CGFloat

        var maxSide: CGFloat { max(horizontal, max(top, bottom)) }
    }

    private static func photoFramePaddings(
        for photoSize: CGSize,
        borderPercent: CGFloat,
        showsCaption: Bool
    ) -> PhotoFramePaddings {
        let percent = min(max(borderPercent, 2), 18) / 100
        if showsCaption {
            let horizontal = photoSize.width * percent
            let top = photoSize.height * percent
            return PhotoFramePaddings(
                horizontal: horizontal,
                top: top,
                bottom: top * 1.45
            )
        }

        let uniform = min(photoSize.width, photoSize.height) * percent
        return PhotoFramePaddings(
            horizontal: uniform,
            top: uniform,
            bottom: uniform
        )
    }

    static func applyPhotoFrame(
        to image: UIImage,
        borderPercent: CGFloat = 8.0,
        showsCaption: Bool = true,
        caption: String? = nil
    ) -> UIImage {
        let source = ImageLoader.normalized(image)
        let pads = photoFramePaddings(
            for: source.size,
            borderPercent: borderPercent,
            showsCaption: showsCaption
        )

        let cardSize = CGSize(
            width: source.size.width + pads.horizontal * 2,
            height: source.size.height + pads.top + pads.bottom
        )
        let photoRect = CGRect(
            x: pads.horizontal,
            y: pads.top,
            width: source.size.width,
            height: source.size.height
        )

        return ImageLoader.renderOpaque(size: cardSize, scale: source.scale) { context in
            context.interpolationQuality = .high

            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: cardSize))

            drawPhotoShadow(
                in: context,
                photoRect: photoRect,
                photoSize: source.size,
                pads: pads
            )

            source.draw(in: photoRect)

            if showsCaption, let caption, !caption.isEmpty {
                let fontSize = photoFrameCaptionFontSize(
                    photoWidth: source.size.width,
                    bottomPadding: pads.bottom
                )
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
                    .foregroundColor: UIColor.darkGray.withAlphaComponent(0.9)
                ]
                let textSize = caption.size(withAttributes: attrs)
                let centerX = (cardSize.width - textSize.width) / 2
                let bottomY = cardSize.height - pads.bottom + (pads.bottom - textSize.height) / 2
                caption.draw(at: CGPoint(x: centerX, y: bottomY), withAttributes: attrs)
            }
        } ?? source
    }

    /// 3D lift shadow with fixed bandwidth (photo-relative). Border only changes mat room.
    private static func drawPhotoShadow(
        in context: CGContext,
        photoRect: CGRect,
        photoSize: CGSize,
        pads: PhotoFramePaddings
    ) {
        let metrics = photoFrameShadowMetrics(photoSize: photoSize, pads: pads)

        let shadowBand = CGRect(
            x: photoRect.minX - pads.horizontal,
            y: photoRect.minY - pads.top,
            width: photoRect.width + pads.horizontal * 2,
            height: photoRect.height + pads.top + metrics.bandDepth
        )

        context.saveGState()
        context.clip(to: shadowBand)

        drawPhotoShadowPass(
            in: context,
            photoRect: photoRect,
            offset: metrics.offset,
            blur: metrics.coreBlur,
            alpha: metrics.coreAlpha,
            fillWhite: false
        )

        drawPhotoShadowPass(
            in: context,
            photoRect: photoRect,
            offset: metrics.offset,
            blur: metrics.softBlur,
            alpha: metrics.softAlpha,
            fillWhite: false
        )

        context.restoreGState()
    }

    private struct PhotoFrameShadowMetrics {
        let offset: CGSize
        let coreBlur: CGFloat
        let softBlur: CGFloat
        let coreAlpha: CGFloat
        let softAlpha: CGFloat
        let bandDepth: CGFloat
    }

    private static func photoFrameShadowMetrics(
        photoSize: CGSize,
        pads: PhotoFramePaddings
    ) -> PhotoFrameShadowMetrics {
        let photoReference = sqrt(photoSize.width * photoSize.height)
        let sideMat = min(pads.horizontal, pads.top)

        let spread = photoReference * frameShadowSpreadFactor
        let bandDepth = min(spread, sideMat)

        var offsetLen = spread * 0.46
        var coreBlur = spread * 0.20
        var softBlur = spread * 0.30

        let footprint = offsetLen + softBlur * 0.78
        if footprint > bandDepth * 0.98, footprint > 0 {
            let scale = (bandDepth * 0.98) / footprint
            offsetLen *= scale
            coreBlur *= scale
            softBlur *= scale
        }

        return PhotoFrameShadowMetrics(
            offset: CGSize(width: offsetLen, height: offsetLen),
            coreBlur: coreBlur,
            softBlur: softBlur,
            coreAlpha: 0.38,
            softAlpha: 0.13,
            bandDepth: bandDepth
        )
    }

    private static func drawPhotoShadowPass(
        in context: CGContext,
        photoRect: CGRect,
        offset: CGSize,
        blur: CGFloat,
        alpha: CGFloat,
        fillWhite: Bool = false
    ) {
        context.saveGState()
        context.setShadow(
            offset: offset,
            blur: blur,
            color: UIColor.black.withAlphaComponent(min(0.92, alpha)).cgColor
        )
        if fillWhite {
            context.setFillColor(UIColor.white.cgColor)
        } else {
            context.setFillColor(UIColor.black.cgColor)
        }
        context.fill(photoRect)
        context.restoreGState()
    }

    private static func photoFrameCaptionFontSize(
        photoWidth: CGFloat,
        bottomPadding: CGFloat
    ) -> CGFloat {
        let scaled = photoWidth * 0.042
        let minimum = max(24, bottomPadding * 0.55)
        let maximum = photoWidth * 0.07
        return min(max(scaled, minimum), maximum)
    }

    // MARK: - Retouch

    private static let retouchCIContext = CIContext(options: nil)
    private static let retouchBlurRadius: CGFloat = 12

    /// Applies each stroke path independently (finger-up to finger-down must not join).
    static func applyRetouch(
        to image: UIImage,
        normalizedStrokePaths: [[CGPoint]],
        brushDiameter: CGFloat
    ) -> UIImage {
        var current = ImageLoader.normalized(image)
        for path in normalizedStrokePaths where !path.isEmpty {
            current = applyRetouch(
                to: current,
                normalizedStrokes: path,
                brushDiameter: brushDiameter
            )
        }
        return current
    }

    static func applyRetouch(
        to image: UIImage,
        normalizedStrokes: [CGPoint],
        brushDiameter: CGFloat
    ) -> UIImage {
        let source = ImageLoader.normalized(image)
        guard !normalizedStrokes.isEmpty else { return source }

        let imagePoints = normalizedStrokes.map { denormalizedPoint($0, imageSize: source.size) }
        let thinned = thinnedStrokePoints(imagePoints, minSpacing: max(brushDiameter / 5, 3))

        if MIGANInpaintEngine.isModelAvailable,
           let inpainted = try? MIGANInpaintEngine.inpaint(
               image: source,
               strokePoints: thinned,
               brushDiameter: brushDiameter
           ) {
            return inpainted
        }

        return RetouchBlurInpaint.inpaint(
            image: source,
            strokePoints: thinned,
            brushDiameter: brushDiameter
        ) ?? applyRetouchWithBlur(
            to: source,
            imagePoints: thinned,
            brushDiameter: brushDiameter
        )
    }

    private static func applyRetouchWithBlur(
        to source: UIImage,
        imagePoints: [CGPoint],
        brushDiameter: CGFloat
    ) -> UIImage {
        var composite: UIImage?

        for index in imagePoints.indices {
            let start = index == 0 ? nil : imagePoints[index - 1]
            let end = imagePoints[index]
            composite = applyRetouchStamp(
                to: composite,
                baseImage: source,
                from: start,
                to: end,
                brushDiameter: brushDiameter
            )
        }

        return composite ?? source
    }

    static func applyRetouchStamp(
        to existingComposite: UIImage?,
        baseImage: UIImage,
        from start: CGPoint?,
        to end: CGPoint,
        brushDiameter: CGFloat
    ) -> UIImage? {
        let source = ImageLoader.normalized(baseImage)
        let composite = existingComposite ?? source
        let bounds = CGRect(origin: .zero, size: source.size)
        let points = strokeInterpolation(from: start, to: end, step: max(brushDiameter / 4, 2))

        var result = composite
        for point in points where bounds.contains(point) {
            result = stampRetouchPoint(
                on: result,
                originalBase: source,
                center: point,
                brushDiameter: brushDiameter
            ) ?? result
        }
        return result
    }

    static func renderRetouchOverlay(
        for baseImage: UIImage,
        normalizedStrokes: [CGPoint],
        brushDiameter: CGFloat
    ) -> UIImage? {
        let source = ImageLoader.normalized(baseImage)
        guard !normalizedStrokes.isEmpty else { return nil }

        let imagePoints = normalizedStrokes.map { denormalizedPoint($0, imageSize: source.size) }
        var composite: UIImage?

        for index in imagePoints.indices {
            let start = index == 0 ? nil : imagePoints[index - 1]
            let end = imagePoints[index]
            composite = applyRetouchStamp(
                to: composite,
                baseImage: source,
                from: start,
                to: end,
                brushDiameter: brushDiameter
            )
        }

        guard let composite else { return nil }
        return extractRetouchOverlay(from: composite, base: source)
    }

    static func compositeRetouch(base: UIImage, overlay: UIImage?) -> UIImage {
        guard let overlay else { return ImageLoader.normalized(base) }
        let source = ImageLoader.normalized(base)
        return ImageLoader.renderOpaque(size: source.size, scale: source.scale) { _ in
            source.draw(in: CGRect(origin: .zero, size: source.size))
            overlay.draw(in: CGRect(origin: .zero, size: source.size))
        } ?? source
    }

    /// Returns only the painted blur layer for legacy export paths.
    private static func extractRetouchOverlay(from composite: UIImage, base: UIImage) -> UIImage? {
        ImageLoader.renderTransparent(size: base.size, scale: base.scale) { _ in
            composite.draw(in: CGRect(origin: .zero, size: base.size))
            base.draw(in: CGRect(origin: .zero, size: base.size), blendMode: .destinationOut, alpha: 1)
        }
    }

    private static func stampRetouchPoint(
        on composite: UIImage,
        originalBase: UIImage,
        center: CGPoint,
        brushDiameter: CGFloat
    ) -> UIImage? {
        let radius = brushDiameter / 2
        let imageBounds = CGRect(origin: .zero, size: originalBase.size)
        let circleRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: brushDiameter,
            height: brushDiameter
        )
        guard circleRect.intersects(imageBounds) else { return composite }

        let sampleRect = circleRect
            .insetBy(dx: -retouchBlurRadius * 2, dy: -retouchBlurRadius * 2)
            .intersection(imageBounds)
        guard sampleRect.width > 0, sampleRect.height > 0,
              let blurredPatch = blurredRegion(from: originalBase, in: sampleRect, radius: retouchBlurRadius) else {
            return composite
        }

        return ImageLoader.renderOpaque(size: originalBase.size, scale: originalBase.scale) { context in
            composite.draw(in: imageBounds)
            context.saveGState()
            context.addEllipse(in: circleRect)
            context.clip()
            blurredPatch.draw(in: sampleRect)
            context.restoreGState()
        }
    }

    /// Flat retouch preview: committed composite + in-progress colored mask in one image.
    static func compositeRetouchPreview(base: UIImage, mask: UIImage?) -> UIImage {
        guard let mask else { return base }
        let canvas = CGRect(origin: .zero, size: base.size)
        return ImageLoader.renderOpaque(size: base.size, scale: base.scale) { _ in
            base.draw(in: canvas)
            mask.draw(in: canvas)
        } ?? base
    }

    private static func blurredRegion(from image: UIImage, in rect: CGRect, radius: CGFloat) -> UIImage? {
        guard let patch = croppedPatch(from: image, rect: rect),
              let input = CIImage(image: patch) else { return nil }

        let normalized = input.transformed(by: CGAffineTransform(
            translationX: -input.extent.origin.x,
            y: -input.extent.origin.y
        ))
        let extent = normalized.extent

        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(normalized, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let blurred = filter.outputImage?.cropped(to: extent) else { return nil }
        guard let cgImage = retouchCIContext.createCGImage(blurred, from: extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: patch.scale, orientation: .up)
    }

    private static func croppedPatch(from image: UIImage, rect: CGRect) -> UIImage? {
        let bounds = CGRect(origin: .zero, size: image.size)
        let cropRect = rect.intersection(bounds)
        guard cropRect.width > 1, cropRect.height > 1 else { return nil }

        return ImageLoader.renderTransparent(size: cropRect.size, scale: image.scale) { _ in
            image.draw(at: CGPoint(x: -cropRect.minX, y: -cropRect.minY))
        }
    }

    private static func strokeInterpolation(from start: CGPoint?, to end: CGPoint, step: CGFloat) -> [CGPoint] {
        guard let start, step > 0 else { return [end] }

        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance >= 0.5 else { return [end] }
        guard distance > step else { return [end] }

        let steps = Int(ceil(distance / step))
        return (0...steps).map { index in
            let t = CGFloat(index) / CGFloat(steps)
            return CGPoint(x: start.x + dx * t, y: start.y + dy * t)
        }
    }

    private static func denormalizedPoint(_ point: CGPoint, imageSize: CGSize) -> CGPoint {
        CGPoint(x: point.x * imageSize.width, y: point.y * imageSize.height)
    }

    static func normalizedPoint(_ point: CGPoint, imageSize: CGSize) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return point }
        return CGPoint(x: point.x / imageSize.width, y: point.y / imageSize.height)
    }

    /// Fast colored preview while the user is dragging (no blur).
    static func drawMaskStroke(
        on existingMask: UIImage?,
        canvasSize: CGSize,
        scale: CGFloat,
        from start: CGPoint?,
        to end: CGPoint,
        brushDiameter: CGFloat,
        color: UIColor
    ) -> UIImage? {
        let points = strokeInterpolation(from: start, to: end, step: max(brushDiameter / 4, 2))
        let radius = brushDiameter / 2
        let fillColor = color.withAlphaComponent(0.5)

        // Use UIKit coordinates (origin top-left) so stroke matches finger position.
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { _ in
            if let existingMask {
                existingMask.draw(in: CGRect(origin: .zero, size: canvasSize))
            }
            fillColor.setFill()
            for point in points {
                UIBezierPath(ovalIn: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: brushDiameter,
                    height: brushDiameter
                )).fill()
            }
        }
    }

    /// White-on-black mask for inpainting.
    static func rasterizeInpaintMask(
        points: [CGPoint],
        brushDiameter: CGFloat,
        canvasSize: CGSize,
        scale: CGFloat
    ) -> UIImage? {
        guard !points.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else { return nil }

        let radius = brushDiameter / 2
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: canvasSize))
            UIColor.white.setFill()

            func stamp(at point: CGPoint) {
                UIBezierPath(ovalIn: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: brushDiameter,
                    height: brushDiameter
                )).fill()
            }

            if points.count == 1 {
                stamp(at: points[0])
                return
            }

            for index in 1..<points.count {
                let segmentPoints = strokeInterpolation(
                    from: points[index - 1],
                    to: points[index],
                    step: max(brushDiameter / 4, 2)
                )
                for point in segmentPoints {
                    stamp(at: point)
                }
            }
        }
    }

    /// Fast crop + blur fill when MI-GAN is unavailable.
    static func commitRetouchPathQuick(
        on composite: UIImage,
        points: [CGPoint],
        brushDiameter: CGFloat
    ) -> UIImage {
        let source = ImageLoader.normalized(composite)
        guard !points.isEmpty else { return source }
        let thinned = thinnedStrokePoints(points, minSpacing: max(brushDiameter / 4, 4))
        return RetouchBlurInpaint.inpaint(
            image: source,
            strokePoints: thinned,
            brushDiameter: brushDiameter
        ) ?? source
    }

    /// Apply AI inpainting along a completed stroke: MI-GAN → blur.
    static func commitRetouchPath(
        on composite: UIImage,
        originalBase: UIImage,
        points: [CGPoint],
        brushDiameter: CGFloat
    ) -> UIImage {
        let source = ImageLoader.normalized(composite)
        guard !points.isEmpty else { return source }
        let thinned = thinnedStrokePoints(points, minSpacing: max(brushDiameter / 5, 3))

        if MIGANInpaintEngine.isModelAvailable {
            do {
                return try MIGANInpaintEngine.inpaint(
                    image: source,
                    strokePoints: thinned,
                    brushDiameter: brushDiameter
                )
            } catch {
                print("MI-GAN inpaint failed: \(error.localizedDescription)")
            }
        }

        return commitRetouchPathQuick(
            on: source,
            points: thinned,
            brushDiameter: brushDiameter
        )
    }

    private static func thinnedStrokePoints(_ points: [CGPoint], minSpacing: CGFloat) -> [CGPoint] {
        guard points.count > 2, minSpacing > 0 else { return points }
        var result: [CGPoint] = [points[0]]
        for point in points.dropFirst() {
            let last = result[result.count - 1]
            if hypot(point.x - last.x, point.y - last.y) >= minSpacing {
                result.append(point)
            }
        }
        if let last = points.last, result.last != last {
            result.append(last)
        }
        return result
    }

    // MARK: - Device Frame (legacy)

    static func deviceFramePreview(for template: DeviceFrameTemplate) -> UIImage {
        loadFrameImage(for: template)
    }

    static func applyDeviceFrame(to screenshot: UIImage, settings: WatermarkSettings) -> UIImage {
        let template = settings.deviceTemplate
        let canvasSize = template.canvasSize
        let frameImage = loadFrameImage(for: template)
        let screenRect = CGRect(
            x: template.screenRect.origin.x * canvasSize.width,
            y: template.screenRect.origin.y * canvasSize.height,
            width: template.screenRect.size.width * canvasSize.width,
            height: template.screenRect.size.height * canvasSize.height
        )

        return ImageLoader.renderOpaque(size: canvasSize, scale: 1) { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize))

            let fitted = aspectFillRect(for: screenshot.size, in: screenRect)
            screenshot.draw(in: fitted)
            frameImage.draw(in: CGRect(origin: .zero, size: canvasSize))

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 36, weight: .medium),
                .foregroundColor: UIColor.darkGray.withAlphaComponent(settings.opacity)
            ]
            let text = settings.text.isEmpty ? "Watermarkly" : settings.text
            let textSize = text.size(withAttributes: attrs)
            let textPoint = CGPoint(
                x: (canvasSize.width - textSize.width) / 2,
                y: canvasSize.height - textSize.height - 48
            )
            text.draw(at: textPoint, withAttributes: attrs)
        } ?? screenshot
    }

    // MARK: - Helpers

    private enum WatermarkContent {
        case text(String)
        case image(UIImage)
    }

    private static func watermarkContent(for settings: WatermarkSettings) -> WatermarkContent? {
        if let logo = settings.logo(for: settings.mode) {
            return .image(logo)
        }
        if settings.mode == .corner || settings.mode == .retouch {
            return nil
        }
        let text = settings.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return .text(text)
    }

    private static func textAttributes(fontSize: CGFloat, opacity: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor.black.withAlphaComponent(opacity)
        ]
    }

    private static func contentSize(
        for content: WatermarkContent,
        attributes: [NSAttributedString.Key: Any],
        canvasSize: CGSize,
        settings: WatermarkSettings
    ) -> CGSize {
        switch content {
        case .text(let string):
            return string.size(withAttributes: attributes)
        case .image:
            return logoDrawSize(canvasSize: canvasSize, settings: settings)
        }
    }

    /// Logo draw size relative to the photo, not the logo file's pixel dimensions.
    private static func logoDrawSize(canvasSize: CGSize, settings: WatermarkSettings) -> CGSize {
        let reference = min(canvasSize.width, canvasSize.height)
        let side: CGFloat
        switch settings.mode {
        case .tiled:
            side = max(reference * 0.12 * settings.tiledScale, 24)
        case .corner:
            side = max(reference * settings.cornerScale, 24)
        case .card, .cutout, .retouch:
            side = 24
        }
        return CGSize(width: side, height: side)
    }

    private static func rotatedBoundingSize(for size: CGSize, radians: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        let cosA = abs(cos(radians))
        let sinA = abs(sin(radians))
        return CGSize(
            width: size.width * cosA + size.height * sinA,
            height: size.width * sinA + size.height * cosA
        )
    }

    /// Projects canvas corners into the rotated grid axes so tiles cover the full image.
    private static func tiledGridExtents(
        canvasSize: CGSize,
        cosR: CGFloat,
        sinR: CGFloat,
        padding: CGFloat
    ) -> (minU: CGFloat, maxU: CGFloat, minV: CGFloat, maxV: CGFloat) {
        let centerX = canvasSize.width / 2
        let centerY = canvasSize.height / 2
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: canvasSize.width, y: 0),
            CGPoint(x: 0, y: canvasSize.height),
            CGPoint(x: canvasSize.width, y: canvasSize.height)
        ]

        var minU = CGFloat.greatestFiniteMagnitude
        var maxU = -CGFloat.greatestFiniteMagnitude
        var minV = minU
        var maxV = maxU

        for corner in corners {
            let dx = corner.x - centerX
            let dy = corner.y - centerY
            let u = dx * cosR + dy * sinR
            let v = -dx * sinR + dy * cosR
            minU = min(minU, u)
            maxU = max(maxU, u)
            minV = min(minV, v)
            maxV = max(maxV, v)
        }

        return (
            minU - padding,
            maxU + padding,
            minV - padding,
            maxV + padding
        )
    }

    private static func drawWatermarkContent(
        _ content: WatermarkContent,
        in rect: CGRect,
        attributes: [NSAttributedString.Key: Any],
        context: CGContext
    ) {
        switch content {
        case .text(let string):
            string.draw(in: rect, withAttributes: attributes)
        case .image(let image):
            context.saveGState()
            context.setAlpha((attributes[.foregroundColor] as? UIColor)?.cgColor.alpha ?? 1)
            image.draw(in: rect)
            context.restoreGState()
        }
    }

    private static func cornerOrigin(
        for position: CornerPosition,
        contentSize: CGSize,
        imageSize: CGSize,
        padding: CGFloat
    ) -> CGPoint {
        switch position {
        case .topLeft:
            return CGPoint(x: padding, y: padding)
        case .topRight:
            return CGPoint(x: imageSize.width - contentSize.width - padding, y: padding)
        case .bottomLeft:
            return CGPoint(x: padding, y: imageSize.height - contentSize.height - padding)
        case .bottomRight:
            return CGPoint(
                x: imageSize.width - contentSize.width - padding,
                y: imageSize.height - contentSize.height - padding
            )
        case .center:
            return CGPoint(
                x: (imageSize.width - contentSize.width) / 2,
                y: (imageSize.height - contentSize.height) / 2
            )
        }
    }

    private static func aspectFillRect(for contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0 else { return bounds }

        let widthRatio = bounds.width / contentSize.width
        let heightRatio = bounds.height / contentSize.height
        let ratio = max(widthRatio, heightRatio)

        let scaledSize = CGSize(width: contentSize.width * ratio, height: contentSize.height * ratio)
        return CGRect(
            x: bounds.midX - scaledSize.width / 2,
            y: bounds.midY - scaledSize.height / 2,
            width: scaledSize.width,
            height: scaledSize.height
        )
    }

    private static func loadFrameImage(for template: DeviceFrameTemplate) -> UIImage {
        if let asset = UIImage(named: template.assetName) {
            return asset
        }
        return placeholderFrame(for: template)
    }

    /// Programmatic placeholder until real PNG device frames are added to Assets.
    private static func placeholderFrame(for template: DeviceFrameTemplate) -> UIImage {
        let size = template.canvasSize
        return ImageLoader.renderOpaque(size: size, scale: 1) { context in
            let rect = CGRect(origin: .zero, size: size)
            let screen = template.screenRect
            let screenRect = CGRect(
                x: screen.origin.x * size.width,
                y: screen.origin.y * size.height,
                width: screen.size.width * size.width,
                height: screen.size.height * size.height
            )

            context.setFillColor(UIColor(white: 0.92, alpha: 1).cgColor)
            context.fill(rect)

            context.setFillColor(UIColor(white: 0.82, alpha: 1).cgColor)
            context.fill(screenRect.insetBy(dx: -6, dy: -6))

            context.setStrokeColor(UIColor(white: 0.25, alpha: 1).cgColor)
            context.setLineWidth(10)
            context.stroke(rect.insetBy(dx: 20, dy: 20))

            context.setLineWidth(3)
            context.stroke(screenRect)

            let label = template.title
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .bold),
                .foregroundColor: UIColor.darkGray
            ]
            let labelSize = label.size(withAttributes: attrs)
            label.draw(
                at: CGPoint(x: (size.width - labelSize.width) / 2, y: 36),
                withAttributes: attrs
            )
        } ?? UIImage()
    }

    // MARK: - Cutout (Vision, on-device)

    /// Removes the photo background and composites the subject onto a white canvas (original dimensions).
    static func removeBackground(from image: UIImage) throws -> UIImage {
        guard isValidImage(image) else { throw CutoutError.invalidImage }
        guard #available(iOS 17.0, *) else { throw CutoutError.unavailable }
        return try removeBackgroundWithVision(from: ImageLoader.normalized(image))
    }

    @available(iOS 17.0, *)
    private static func removeBackgroundWithVision(from source: UIImage) throws -> UIImage {
        guard let cgImage = source.cgImage else { throw CutoutError.invalidImage }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first else {
            throw CutoutError.noSubjectFound
        }

        let instances = observation.allInstances
        guard !instances.isEmpty else { throw CutoutError.noSubjectFound }

        let maskBuffer = try observation.generateScaledMaskForImage(forInstances: instances, from: handler)
        return compositeSubjectOnWhite(source: source, maskBuffer: maskBuffer)
    }

    @available(iOS 17.0, *)
    private static func compositeSubjectOnWhite(source: UIImage, maskBuffer: CVPixelBuffer) -> UIImage {
        guard let cgImage = source.cgImage else { return source }

        let sourceCI = CIImage(cgImage: cgImage)
        var maskCI = CIImage(cvPixelBuffer: maskBuffer)

        let sourceExtent = sourceCI.extent
        if maskCI.extent.size != sourceExtent.size {
            let scaleX = sourceExtent.width / maskCI.extent.width
            let scaleY = sourceExtent.height / maskCI.extent.height
            maskCI = maskCI.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }

        let white = CIImage(color: CIColor.white).cropped(to: sourceExtent)
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return source }
        filter.setValue(sourceCI, forKey: kCIInputImageKey)
        filter.setValue(white, forKey: kCIInputBackgroundImageKey)
        filter.setValue(maskCI, forKey: kCIInputMaskImageKey)

        guard let output = filter.outputImage else { return source }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let outputCG = context.createCGImage(output, from: sourceExtent) else { return source }

        return UIImage(cgImage: outputCG, scale: source.scale, orientation: .up)
    }

    // MARK: - Collage layout

    static func flattenLayeredPreview(base: UIImage, overlay: UIImage) -> UIImage? {
        let normalizedBase = ImageLoader.normalized(base)
        let normalizedOverlay = ImageLoader.normalized(overlay)
        let size = normalizedBase.size
        return ImageLoader.renderOpaque(size: size, scale: normalizedBase.scale) { _ in
            normalizedBase.draw(in: CGRect(origin: .zero, size: size))
            normalizedOverlay.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func layoutImages(_ images: [UIImage], options: CollageLayoutOptions) -> UIImage? {
        CollageLayoutEngine.layoutImages(images, options: options)
    }

    static func layoutImages(_ images: [UIImage], layoutType: CollageLayoutType) -> UIImage? {
        layoutImages(images, options: CollageLayoutOptions(layoutType: layoutType))
    }
}
