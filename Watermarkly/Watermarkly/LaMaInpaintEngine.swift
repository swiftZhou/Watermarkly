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

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let modelLock = NSLock()
    private static var cachedModel: LaMa?
    private static let minimumCropSide: CGFloat = 64

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

    static func inpaint(
        image: UIImage,
        strokePoints: [CGPoint],
        brushDiameter: CGFloat,
        maxWorkingPixelSize: CGFloat = ImageLimits.retouchPreviewInpaintMaxPixelSize
    ) throws -> UIImage {
        let source = ImageLoader.normalized(image)
        guard !strokePoints.isEmpty else { return source }

        let cropRect = strokeCropRect(
            points: strokePoints,
            brushDiameter: brushDiameter,
            canvasSize: source.size
        )
        guard cropRect.width > 0, cropRect.height > 0,
              let croppedImage = crop(source, to: cropRect) else {
            return source
        }

        let localPoints = strokePoints.map {
            CGPoint(x: $0.x - cropRect.minX, y: $0.y - cropRect.minY)
        }
        guard let mask = WatermarkEngine.rasterizeInpaintMask(
            points: localPoints,
            brushDiameter: brushDiameter,
            canvasSize: cropRect.size,
            scale: croppedImage.scale
        ) else {
            return source
        }

        let (workingImage, workingMask) = downscaleForInference(
            image: croppedImage,
            mask: mask,
            maxPixelSize: maxWorkingPixelSize
        )
        let inpaintedWorking = try inpaint(image: workingImage, mask: workingMask)
        let inpaintedCrop = resize(
            inpaintedWorking,
            to: cropRect.size,
            scale: croppedImage.scale
        )
        return composite(base: source, patch: inpaintedCrop, at: cropRect)
    }

    static func inpaint(image: UIImage, mask: UIImage) throws -> UIImage {
        let source = ImageLoader.normalized(image)
        let maskImage = ImageLoader.normalized(mask)
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
            configuration.computeUnits = .all
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

    private static func strokeCropRect(
        points: [CGPoint],
        brushDiameter: CGFloat,
        canvasSize: CGSize
    ) -> CGRect {
        let radius = brushDiameter / 2
        let padding = max(brushDiameter * 1.5, 24)
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

    private static func composite(base: UIImage, patch: UIImage, at rect: CGRect) -> UIImage {
        ImageLoader.renderOpaque(size: base.size, scale: base.scale) { _ in
            base.draw(in: CGRect(origin: .zero, size: base.size))
            patch.draw(in: rect)
        } ?? base
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
            width: (image.size.width * image.scale * ratio).rounded(.down),
            height: (image.size.height * image.scale * ratio).rounded(.down)
        )
        guard targetSize.width > 0, targetSize.height > 0 else {
            return (image, mask)
        }

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
