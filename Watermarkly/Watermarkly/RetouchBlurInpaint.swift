import UIKit

/// Lightweight crop-local blur fill when MI-GAN is unavailable.
enum RetouchBlurInpaint {

    private static let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])
    private static let minimumCropSide: CGFloat = 48
    private static let blurRadius: CGFloat = 18

    static func inpaint(
        image: UIImage,
        strokePoints: [CGPoint],
        brushDiameter: CGFloat
    ) -> UIImage? {
        let source = image.imageOrientation == .up ? image : ImageLoader.normalized(image)
        guard !strokePoints.isEmpty else { return nil }

        let cropRect = strokeCropRect(
            points: strokePoints,
            brushDiameter: brushDiameter,
            canvasSize: source.size
        )
        guard cropRect.width > 1, cropRect.height > 1,
              let cropped = crop(source, to: cropRect) else { return nil }

        let localPoints = strokePoints.map {
            CGPoint(x: $0.x - cropRect.minX, y: $0.y - cropRect.minY)
        }
        guard let mask = WatermarkEngine.rasterizeInpaintMask(
            points: localPoints,
            brushDiameter: brushDiameter,
            canvasSize: cropRect.size,
            scale: 1
        ) else { return nil }

        let work = downscaleImage(cropped, maxPixelSize: 256) ?? cropped
        let workMask = downscaleImage(mask, maxPixelSize: 256) ?? mask
        guard let blurredWork = blurImage(work, radius: blurRadius) else {
            return paste(patch: cropped, into: source, at: cropRect)
        }

        let blurredCrop = resize(blurredWork, to: cropRect.size)
        let maskForBlend = resize(workMask, to: cropRect.size)
        let blendedCrop = blendWithMask(image: blurredCrop, background: cropped, mask: maskForBlend)
            ?? blurredCrop
        return paste(patch: blendedCrop, into: source, at: cropRect)
    }

    private static func downscaleImage(_ image: UIImage, maxPixelSize: CGFloat) -> UIImage? {
        let maxSide = max(image.size.width, image.size.height) * image.scale
        guard maxSide > maxPixelSize else { return image }
        let ratio = maxPixelSize / maxSide
        let target = CGSize(
            width: max((image.size.width * image.scale * ratio).rounded(.down), 1),
            height: max((image.size.height * image.scale * ratio).rounded(.down), 1)
        )
        return ImageLoader.renderOpaque(size: target, scale: 1) { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func strokeCropRect(
        points: [CGPoint],
        brushDiameter: CGFloat,
        canvasSize: CGSize
    ) -> CGRect {
        let radius = brushDiameter / 2
        let padding = max(brushDiameter, 16)
        var minX = points[0].x - radius
        var maxX = points[0].x + radius
        var minY = points[0].y - radius
        var maxY = points[0].y + radius

        for point in points.dropFirst() {
            minX = min(minX, point.x - radius)
            maxX = max(maxX, point.x + radius)
            minY = min(minY, point.y - radius)
            maxY = max(maxY, point.y + radius)
        }

        var rect = CGRect(
            x: minX - padding,
            y: minY - padding,
            width: (maxX - minX) + padding * 2,
            height: (maxY - minY) + padding * 2
        )
        let canvas = CGRect(origin: .zero, size: canvasSize)
        rect = rect.intersection(canvas)

        if rect.width < minimumCropSide {
            let delta = (minimumCropSide - rect.width) / 2
            rect.origin.x = max(canvas.minX, rect.origin.x - delta)
            rect.size.width = min(canvas.maxX - rect.minX, minimumCropSide)
        }
        if rect.height < minimumCropSide {
            let delta = (minimumCropSide - rect.height) / 2
            rect.origin.y = max(canvas.minY, rect.origin.y - delta)
            rect.size.height = min(canvas.maxY - rect.minY, minimumCropSide)
        }

        return rect.integral
    }

    private static func crop(_ image: UIImage, to rect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let scale = image.scale
        let pixelRect = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.size.width * scale,
            height: rect.size.height * scale
        ).integral
        guard let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: .up)
    }

    private static func paste(patch: UIImage, into base: UIImage, at rect: CGRect) -> UIImage {
        ImageLoader.renderOpaque(size: base.size, scale: base.scale) { _ in
            base.draw(in: CGRect(origin: .zero, size: base.size))
            patch.draw(in: rect)
        } ?? base
    }

    private static func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        ImageLoader.renderOpaque(size: size, scale: 1) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        } ?? image
    }

    private static func blendWithMask(image: UIImage, background: UIImage, mask: UIImage) -> UIImage? {
        guard let foreground = CIImage(image: image),
              let bg = CIImage(image: background),
              let maskCI = CIImage(image: mask) else { return nil }

        let extent = bg.extent
        let fg = foreground.transformed(by: CGAffineTransform(
            translationX: -foreground.extent.origin.x,
            y: -foreground.extent.origin.y
        )).cropped(to: extent)
        let mk = maskCI.transformed(by: CGAffineTransform(
            translationX: -maskCI.extent.origin.x,
            y: -maskCI.extent.origin.y
        )).cropped(to: extent)

        guard let filter = CIFilter(name: "CIBlendWithMask") else { return nil }
        filter.setValue(fg, forKey: kCIInputImageKey)
        filter.setValue(bg, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mk, forKey: kCIInputMaskImageKey)
        guard let output = filter.outputImage?.cropped(to: extent),
              let cgImage = ciContext.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private static func blurImage(_ image: UIImage, radius: CGFloat) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let normalized = input.transformed(by: CGAffineTransform(
            translationX: -input.extent.origin.x,
            y: -input.extent.origin.y
        ))
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(normalized, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        let extent = normalized.extent
        guard let output = filter.outputImage?.cropped(to: extent),
              let cgImage = ciContext.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
    }
}
