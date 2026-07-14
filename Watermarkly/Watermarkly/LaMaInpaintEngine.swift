import CoreML
import UIKit

enum LaMaInpaintError: LocalizedError {
    case modelMissing
    case modelLoadFailed(String)
    case invalidImage
    case invalidMask
    case predictionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "LaMa model is missing from the app bundle."
        case .modelLoadFailed(let message):
            return "Failed to load LaMa model: \(message)"
        case .invalidImage:
            return "Invalid source image for inpainting."
        case .invalidMask:
            return "Invalid inpainting mask."
        case .predictionFailed(let message):
            return "Inpainting failed: \(message)"
        }
    }
}

/// On-device LaMa inpainting via Core ML (800×800 image + grayscale mask).
enum LaMaInpaintEngine {

    private static let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])
    private static let modelLock = NSLock()
    private static var cachedModel: LaMa?
    private static let minimumCropSide: CGFloat = 48
    private static let quickBlurRadius: CGFloat = 18

    static var isModelAvailable: Bool {
        Bundle.main.url(forResource: "LaMa", withExtension: "mlmodelc") != nil
            || Bundle.main.url(forResource: "LaMa", withExtension: "mlpackage") != nil
    }

    static func prepareModel(completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let model = try loadModel()
                try warmUp(model)
                DispatchQueue.main.async { completion?(true) }
            } catch {
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }

    /// Instant crop-local blur for Retouch preview (milliseconds, not seconds).
    static func quickBlurInpaint(
        image: UIImage,
        strokePoints: [CGPoint],
        brushDiameter: CGFloat
    ) -> UIImage? {
        let source = ensureUpOrientation(image)
        guard !strokePoints.isEmpty else { return nil }

        let cropRect = strokeCropRect(
            points: strokePoints,
            brushDiameter: brushDiameter,
            canvasSize: source.size,
            paddingFactor: 1.0
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

        // Downscale large crops before blur — blur of a 200pt brush crop on a 1200px
        // preview is cheap; avoid blurring multi-megapixel patches.
        let work = downscaleImage(cropped, maxPixelSize: 256) ?? cropped
        let workMask = downscaleImage(mask, maxPixelSize: 256) ?? mask
        guard let blurredWork = blurImage(work, radius: quickBlurRadius) else {
            return paste(patch: cropped, into: source, at: cropRect)
        }

        let blurredCrop = resize(blurredWork, to: cropRect.size, scale: 1)
        let maskForBlend = resize(workMask, to: cropRect.size, scale: 1)
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

    static func inpaint(
        image: UIImage,
        strokePoints: [CGPoint],
        brushDiameter: CGFloat,
        maxWorkingPixelSize: CGFloat = ImageLimits.retouchPreviewInpaintMaxPixelSize
    ) throws -> UIImage {
        let source = ensureUpOrientation(image)
        guard !strokePoints.isEmpty else { return source }

        let cropRect = strokeCropRect(
            points: strokePoints,
            brushDiameter: brushDiameter,
            canvasSize: source.size,
            paddingFactor: 1.2
        )
        guard cropRect.width > 0, cropRect.height > 0,
              let croppedImage = crop(source, to: cropRect) else {
            return source
        }

        let localPoints = strokePoints.map {
            CGPoint(x: $0.x - cropRect.minX, y: $0.y - cropRect.minY)
        }
        // Always rasterize at scale 1 — Core ML resizes to 800×800 anyway.
        guard let mask = WatermarkEngine.rasterizeInpaintMask(
            points: localPoints,
            brushDiameter: brushDiameter,
            canvasSize: cropRect.size,
            scale: 1
        ) else {
            return source
        }

        let (workingImage, workingMask) = downscaleForInference(
            image: croppedImage,
            mask: mask,
            maxPixelSize: maxWorkingPixelSize
        )
        let inpaintedWorking = try inpaint(image: workingImage, mask: workingMask)
        let inpaintedCrop = resize(inpaintedWorking, to: cropRect.size, scale: 1)
        // Softly preserve outside-mask pixels from the original crop.
        let blendedCrop = blendWithMask(image: inpaintedCrop, background: croppedImage, mask: mask)
            ?? inpaintedCrop
        return paste(patch: blendedCrop, into: source, at: cropRect)
    }

    static func inpaint(image: UIImage, mask: UIImage) throws -> UIImage {
        let source = ensureUpOrientation(image)
        let maskImage = ensureUpOrientation(mask)
        guard let imageCG = source.cgImage else { throw LaMaInpaintError.invalidImage }
        guard let maskCG = maskImage.cgImage else { throw LaMaInpaintError.invalidMask }

        let model = try loadModel()
        let input = try LaMaInput(imageWith: imageCG, maskWith: maskCG)
        let output = try model.prediction(input: input)

        let inpaintedSquare = try pixelBufferToUIImage(output.output)
        return resize(inpaintedSquare, to: source.size, scale: source.scale)
    }

    private static func loadModel() throws -> LaMa {
        modelLock.lock()
        defer { modelLock.unlock() }

        if let cachedModel {
            return cachedModel
        }

        guard isModelAvailable else {
            throw LaMaInpaintError.modelMissing
        }

        do {
            let configuration = MLModelConfiguration()
            // Neural Engine is typically fastest for this model on modern iPhones.
            if #available(iOS 16.0, *) {
                configuration.computeUnits = .cpuAndNeuralEngine
            } else {
                configuration.computeUnits = .all
            }
            let model = try LaMa(configuration: configuration)
            cachedModel = model
            return model
        } catch {
            throw LaMaInpaintError.modelLoadFailed(error.localizedDescription)
        }
    }

    private static func warmUp(_ model: LaMa) throws {
        let size = CGSize(width: 64, height: 64)
        guard let image = ImageLoader.renderOpaque(size: size, scale: 1, draw: { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }), let imageCG = image.cgImage else { return }

        guard let mask = ImageLoader.renderOpaque(size: size, scale: 1, draw: { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            ctx.fillEllipse(in: CGRect(x: 24, y: 24, width: 16, height: 16))
        }), let maskCG = mask.cgImage else { return }

        let input = try LaMaInput(imageWith: imageCG, maskWith: maskCG)
        _ = try model.prediction(input: input)
    }

    private static func ensureUpOrientation(_ image: UIImage) -> UIImage {
        image.imageOrientation == .up ? image : ImageLoader.normalized(image)
    }

    private static func strokeCropRect(
        points: [CGPoint],
        brushDiameter: CGFloat,
        canvasSize: CGSize,
        paddingFactor: CGFloat
    ) -> CGRect {
        let radius = brushDiameter / 2
        let padding = max(brushDiameter * paddingFactor, 16)
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

    private static func downscaleForInference(
        image: UIImage,
        mask: UIImage,
        maxPixelSize: CGFloat
    ) -> (UIImage, UIImage) {
        let maxSide = max(image.size.width, image.size.height) * image.scale
        guard maxPixelSize > 0, maxSide > maxPixelSize else {
            return (image, mask)
        }

        let ratio = maxPixelSize / maxSide
        let targetSize = CGSize(
            width: max((image.size.width * image.scale * ratio).rounded(.down), 1),
            height: max((image.size.height * image.scale * ratio).rounded(.down), 1)
        )

        let downscaledImage = ImageLoader.renderOpaque(size: targetSize, scale: 1) { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        } ?? image
        let downscaledMask = ImageLoader.renderOpaque(size: targetSize, scale: 1) { _ in
            mask.draw(in: CGRect(origin: .zero, size: targetSize))
        } ?? mask
        return (downscaledImage, downscaledMask)
    }

    private static func resize(_ image: UIImage, to size: CGSize, scale: CGFloat) -> UIImage {
        ImageLoader.renderOpaque(size: size, scale: scale) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        } ?? image
    }

    private static func pixelBufferToUIImage(_ pixelBuffer: CVPixelBuffer) throws -> UIImage {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw LaMaInpaintError.predictionFailed("Could not render model output.")
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }
}
