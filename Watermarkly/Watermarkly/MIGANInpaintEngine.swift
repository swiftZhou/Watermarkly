import CoreML
import UIKit

enum MIGANInpaintError: LocalizedError {
    case modelMissing
    case invalidImage
    case predictionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "MI-GAN model is missing from the app bundle."
        case .invalidImage:
            return "Invalid source image for inpainting."
        case .predictionFailed(let message):
            return "MI-GAN inpainting failed: \(message)"
        }
    }
}

/// Fast on-device inpainting via MI-GAN Core ML (256×256), MIT (Picsart).
/// For flat UI / white backgrounds (common watermark screenshots), uses edge-color
/// fill first — much cleaner than Places2 textures on solid colors.
enum MIGANInpaintEngine {

    static let modelResolution = 256
    private static let minimumCropSide: CGFloat = 48
    /// Solid UI cards / chat bubbles (any color). Textured photos must use MI-GAN.
    private static let flatLightMin: CGFloat = 228
    private static let flatLightChromaMax: CGFloat = 22
    private static let flatStdMax: CGFloat = 16
    private static let flatEdgeMax: CGFloat = 14
    private static let flatInlierDistance: CGFloat = 36
    private static let modelLock = NSLock()
    private static var cachedModel: migan_coreml?
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static var isModelAvailable: Bool {
        Bundle.main.url(forResource: "migan_coreml", withExtension: "mlmodelc") != nil
            || Bundle.main.url(forResource: "migan_coreml", withExtension: "mlpackage") != nil
    }

    private static var didWarmUp = false

    static func prepareModel(completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ready: Bool
            do {
                let model = try loadModel()
                warmUpIfNeeded(model)
                ready = true
            } catch {
                ready = false
            }
            DispatchQueue.main.async { completion?(ready) }
        }
    }

    static func inpaint(
        image: UIImage,
        strokePoints: [CGPoint],
        brushDiameter: CGFloat
    ) throws -> UIImage {
        let source = image.imageOrientation == .up ? image : ImageLoader.normalized(image)
        guard !strokePoints.isEmpty else { return source }

        let cropRect = strokeCropRect(
            points: strokePoints,
            brushDiameter: brushDiameter,
            canvasSize: source.size
        )
        guard cropRect.width > 1, cropRect.height > 1,
              let cropped = crop(source, to: cropRect) else { return source }

        let localPoints = strokePoints.map {
            CGPoint(x: $0.x - cropRect.minX, y: $0.y - cropRect.minY)
        }
        // Rasterize mask at working size so large phone photos stay cheap.
        let work = downscalePair(image: cropped, maskPoints: localPoints, brushDiameter: brushDiameter, maxSide: 384)
        guard let mask = work.mask else { return source }

        // Solid UI (WeChat bubbles, white cards): opaque flat fill — never MI-GAN/blur smudge.
        if looksLikeFlatUI(image: work.image, holeMask: mask),
           let flatWork = flatBackgroundFill(image: work.image, holeMask: mask) {
            let flat = resize(flatWork, to: cropRect.size)
            return paste(patch: flat, into: source, at: cropRect)
        }

        // Textured photos: MI-GAN @ 256; blend at ≤384 work size (not full-res crop).
        let filledSquare = try inpaintSquare(image: work.image, mask: mask)
        let filledWork = resize(filledSquare, to: work.image.size)
        let blendedWork = softBlendHole(original: work.image, filled: filledWork, holeMask: mask)
            ?? filledWork
        let blended = resize(blendedWork, to: cropRect.size)
        return paste(patch: blended, into: source, at: cropRect)
    }

    // MARK: - Flat background fill (best for UI screenshots)

    /// Cheap gate: dominant solid UI color (green/gray bubbles, white cards) passes;
    /// textured grass/sky fails. Uses dominant-cluster flatness so bubble+dark-bg crops still pass.
    private static func looksLikeFlatUI(image: UIImage, holeMask: UIImage) -> Bool {
        let probeSize = CGSize(width: 64, height: 64)
        let probeImage = resize(image, to: probeSize)
        let probeMask = resize(holeMask, to: probeSize)
        guard let pixels = rgbaPixels(from: probeImage),
              let maskPixels = grayPixels(from: probeMask) else { return false }

        let w = pixels.width
        let h = pixels.height
        var samples: [(CGFloat, CGFloat, CGFloat)] = []
        samples.reserveCapacity(256)

        for y in 0..<h {
            for x in 0..<w {
                let idx = y * w + x
                guard maskPixels.bytes[idx] <= 128 else { continue }
                let o = idx * 4
                samples.append((
                    CGFloat(pixels.bytes[o]),
                    CGFloat(pixels.bytes[o + 1]),
                    CGFloat(pixels.bytes[o + 2])
                ))
            }
        }
        guard samples.count >= 8 else { return false }

        // Quantize to find the dominant solid color (bubble fill vs chat background).
        var bins: [Int: (count: Int, sumR: CGFloat, sumG: CGFloat, sumB: CGFloat)] = [:]
        for s in samples {
            let key = (Int(s.0) / 16) << 10 | (Int(s.1) / 16) << 5 | (Int(s.2) / 16)
            var bin = bins[key] ?? (0, 0, 0, 0)
            bin.count += 1
            bin.sumR += s.0
            bin.sumG += s.1
            bin.sumB += s.2
            bins[key] = bin
        }
        guard let dominant = bins.values.max(by: { $0.count < $1.count }),
              CGFloat(dominant.count) / CGFloat(samples.count) >= 0.42 else { return false }

        let seedR = dominant.sumR / CGFloat(dominant.count)
        let seedG = dominant.sumG / CGFloat(dominant.count)
        let seedB = dominant.sumB / CGFloat(dominant.count)
        let inliers = samples.filter {
            abs($0.0 - seedR) + abs($0.1 - seedG) + abs($0.2 - seedB) <= flatInlierDistance
        }
        guard inliers.count >= 8 else { return false }

        let meanR = inliers.map(\.0).reduce(0, +) / CGFloat(inliers.count)
        let meanG = inliers.map(\.1).reduce(0, +) / CGFloat(inliers.count)
        let meanB = inliers.map(\.2).reduce(0, +) / CGFloat(inliers.count)
        let varR = inliers.map { pow($0.0 - meanR, 2) }.reduce(0, +) / CGFloat(inliers.count)
        let varG = inliers.map { pow($0.1 - meanG, 2) }.reduce(0, +) / CGFloat(inliers.count)
        let varB = inliers.map { pow($0.2 - meanB, 2) }.reduce(0, +) / CGFloat(inliers.count)
        let std = sqrt((varR + varG + varB) / 3)

        // Local edge energy only inside the dominant color (texture detector).
        var edgeSum: CGFloat = 0
        var edgeCount = 0
        func isInlierColor(_ o: Int) -> Bool {
            let r = CGFloat(pixels.bytes[o])
            let g = CGFloat(pixels.bytes[o + 1])
            let b = CGFloat(pixels.bytes[o + 2])
            return abs(r - seedR) + abs(g - seedG) + abs(b - seedB) <= flatInlierDistance
        }
        for y in 0..<h {
            for x in 0..<w {
                let idx = y * w + x
                guard maskPixels.bytes[idx] <= 128 else { continue }
                let o = idx * 4
                guard isInlierColor(o) else { continue }
                let r = CGFloat(pixels.bytes[o])
                let g = CGFloat(pixels.bytes[o + 1])
                let b = CGFloat(pixels.bytes[o + 2])
                if x + 1 < w, maskPixels.bytes[idx + 1] <= 128, isInlierColor((idx + 1) * 4) {
                    let ro = (idx + 1) * 4
                    edgeSum += abs(r - CGFloat(pixels.bytes[ro]))
                        + abs(g - CGFloat(pixels.bytes[ro + 1]))
                        + abs(b - CGFloat(pixels.bytes[ro + 2]))
                    edgeCount += 1
                }
                if y + 1 < h, maskPixels.bytes[idx + w] <= 128, isInlierColor((idx + w) * 4) {
                    let bo = (idx + w) * 4
                    edgeSum += abs(r - CGFloat(pixels.bytes[bo]))
                        + abs(g - CGFloat(pixels.bytes[bo + 1]))
                        + abs(b - CGFloat(pixels.bytes[bo + 2]))
                    edgeCount += 1
                }
            }
        }
        let edge = edgeCount > 0 ? edgeSum / CGFloat(edgeCount) / 3 : 0
        return std <= flatStdMax && edge <= flatEdgeMax
    }

    /// Opaque neighborhood fill — never soft-blends (soft blends of bubble+text = gray fog).
    private static func flatBackgroundFill(image: UIImage, holeMask: UIImage) -> UIImage? {
        guard let pixels = rgbaPixels(from: image),
              let maskPixels = grayPixels(from: holeMask),
              pixels.width == maskPixels.width,
              pixels.height == maskPixels.height else { return nil }

        let w = pixels.width
        let h = pixels.height

        func isHole(_ x: Int, _ y: Int) -> Bool {
            maskPixels.bytes[y * w + x] > 128
        }

        // Dilate the hole so antialiased text fringes under the stroke edge are covered.
        let dilateRadius = 2
        var fillMask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var hit = isHole(x, y)
                if !hit {
                    let x0 = max(x - dilateRadius, 0), x1 = min(x + dilateRadius, w - 1)
                    let y0 = max(y - dilateRadius, 0), y1 = min(y + dilateRadius, h - 1)
                    search: for yy in y0...y1 {
                        for xx in x0...x1 where isHole(xx, yy) {
                            hit = true
                            break search
                        }
                    }
                }
                fillMask[y * w + x] = hit
            }
        }

        // Sample only near the hole edge (perimeter band) — O(perimeter), not O(full crop).
        let sampleInner = dilateRadius + 1
        let sampleOuter = dilateRadius + 6
        var samples: [(CGFloat, CGFloat, CGFloat)] = []
        samples.reserveCapacity(256)

        for y in 0..<h {
            for x in 0..<w {
                guard fillMask[y * w + x] else { continue }
                var isBorder = false
                let bx0 = max(x - 1, 0), bx1 = min(x + 1, w - 1)
                let by0 = max(y - 1, 0), by1 = min(y + 1, h - 1)
                border: for yy in by0...by1 {
                    for xx in bx0...bx1 where !fillMask[yy * w + xx] {
                        isBorder = true
                        break border
                    }
                }
                guard isBorder else { continue }

                let x0 = max(x - sampleOuter, 0), x1 = min(x + sampleOuter, w - 1)
                let y0 = max(y - sampleOuter, 0), y1 = min(y + sampleOuter, h - 1)
                for yy in y0...y1 {
                    for xx in x0...x1 {
                        guard !fillMask[yy * w + xx] else { continue }
                        let dx = xx - x, dy = yy - y
                        let dist = Int(sqrt(Double(dx * dx + dy * dy)))
                        guard dist >= sampleInner, dist <= sampleOuter else { continue }
                        let i = (yy * w + xx) * 4
                        samples.append((
                            CGFloat(pixels.bytes[i]),
                            CGFloat(pixels.bytes[i + 1]),
                            CGFloat(pixels.bytes[i + 2])
                        ))
                    }
                }
            }
        }

        if samples.count < 8 {
            let step = max(1, min(w, h) / 16)
            for y in stride(from: 0, to: h, by: step) {
                for x in stride(from: 0, to: w, by: step) where !fillMask[y * w + x] {
                    let i = (y * w + x) * 4
                    samples.append((
                        CGFloat(pixels.bytes[i]),
                        CGFloat(pixels.bytes[i + 1]),
                        CGFloat(pixels.bytes[i + 2])
                    ))
                }
            }
        }
        guard samples.count >= 4 else { return nil }

        // Drop text / AA outliers, then take the solid bubble / card color.
        let seedR = median(samples.map(\.0))
        let seedG = median(samples.map(\.1))
        let seedB = median(samples.map(\.2))
        let inliers = samples.filter {
            abs($0.0 - seedR) + abs($0.1 - seedG) + abs($0.2 - seedB) <= flatInlierDistance
        }
        let cluster = inliers.count >= 4 ? inliers : samples

        let meanR = cluster.map(\.0).reduce(0, +) / CGFloat(cluster.count)
        let meanG = cluster.map(\.1).reduce(0, +) / CGFloat(cluster.count)
        let meanB = cluster.map(\.2).reduce(0, +) / CGFloat(cluster.count)
        let varR = cluster.map { pow($0.0 - meanR, 2) }.reduce(0, +) / CGFloat(cluster.count)
        let varG = cluster.map { pow($0.1 - meanG, 2) }.reduce(0, +) / CGFloat(cluster.count)
        let varB = cluster.map { pow($0.2 - meanB, 2) }.reduce(0, +) / CGFloat(cluster.count)
        let std = sqrt((varR + varG + varB) / 3)
        guard std <= flatStdMax + 4 else { return nil }

        var fillR = UInt8(min(255, median(cluster.map(\.0)).rounded()))
        var fillG = UInt8(min(255, median(cluster.map(\.1)).rounded()))
        var fillB = UInt8(min(255, median(cluster.map(\.2)).rounded()))

        // White cards only: snap residual gray from text fringes to pure white.
        let chroma = max(meanR, meanG, meanB) - min(meanR, meanG, meanB)
        let isLightCard = meanR >= flatLightMin && meanG >= flatLightMin && meanB >= flatLightMin
            && chroma <= flatLightChromaMax
        if isLightCard {
            fillR = max(fillR, 248)
            fillG = max(fillG, 248)
            fillB = max(fillB, 248)
            if fillR > 250 && fillG > 250 && fillB > 250 {
                fillR = 255; fillG = 255; fillB = 255
            }
        }

        var out = pixels.bytes
        for idx in 0..<(w * h) where fillMask[idx] {
            let i = idx * 4
            out[i] = fillR
            out[i + 1] = fillG
            out[i + 2] = fillB
            out[i + 3] = 255
        }
        return makeUIImage(fromRGBA: out, width: w, height: h)
    }

    private static func downscalePair(
        image: UIImage,
        maskPoints: [CGPoint],
        brushDiameter: CGFloat,
        maxSide: CGFloat
    ) -> (image: UIImage, mask: UIImage?) {
        let maxDim = max(image.size.width, image.size.height)
        guard maxDim > maxSide else {
            let mask = WatermarkEngine.rasterizeInpaintMask(
                points: maskPoints,
                brushDiameter: brushDiameter,
                canvasSize: image.size,
                scale: 1
            )
            return (image, mask)
        }
        let scale = maxSide / maxDim
        let target = CGSize(
            width: max((image.size.width * scale).rounded(), 1),
            height: max((image.size.height * scale).rounded(), 1)
        )
        let scaledImage = resize(image, to: target)
        let scaledPoints = maskPoints.map {
            CGPoint(x: $0.x * scale, y: $0.y * scale)
        }
        let mask = WatermarkEngine.rasterizeInpaintMask(
            points: scaledPoints,
            brushDiameter: brushDiameter * scale,
            canvasSize: target,
            scale: 1
        )
        return (scaledImage, mask)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    // MARK: - Model

    private static func loadModel() throws -> migan_coreml {
        modelLock.lock()
        defer { modelLock.unlock() }
        if let cachedModel { return cachedModel }

        guard isModelAvailable else {
            throw MIGANInpaintError.modelMissing
        }
        let configuration = MLModelConfiguration()
        if #available(iOS 16.0, *) {
            configuration.computeUnits = .cpuAndNeuralEngine
        } else {
            configuration.computeUnits = .all
        }
        let model = try migan_coreml(configuration: configuration)
        cachedModel = model
        return model
    }

    /// First Core ML hit is often 2–5s cold; warm during Retouch mode entry.
    private static func warmUpIfNeeded(_ model: migan_coreml) {
        modelLock.lock()
        let needsWarmUp = !didWarmUp
        if needsWarmUp { didWarmUp = true }
        modelLock.unlock()
        guard needsWarmUp else { return }

        let side = modelResolution
        let blank = ImageLoader.renderOpaque(size: CGSize(width: side, height: side), scale: 1) { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        let hole = ImageLoader.renderOpaque(size: CGSize(width: side, height: side), scale: 1) { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIColor.white.setFill()
            ctx.fillEllipse(in: CGRect(x: side / 4, y: side / 4, width: side / 2, height: side / 2))
        }
        guard let blank, let hole,
              let input = makeInputArray(image: blank, holeMask: hole) else { return }
        _ = try? model.prediction(input_image: input)
    }

    private static func inpaintSquare(image: UIImage, mask: UIImage) throws -> UIImage {
        let model = try loadModel()
        warmUpIfNeeded(model)
        let side = modelResolution
        let resizedImage = resize(image, to: CGSize(width: side, height: side))
        let resizedMask = resize(mask, to: CGSize(width: side, height: side))

        guard let input = makeInputArray(image: resizedImage, holeMask: resizedMask) else {
            throw MIGANInpaintError.invalidImage
        }
        let output = try model.prediction(input_image: input)
        guard let result = imageFromOutputArray(output.output_image) else {
            throw MIGANInpaintError.predictionFailed("Could not decode MI-GAN output.")
        }
        return result
    }

    /// Matches MI-GAN / CoreML sample with invertMask = true for our white-hole masks:
    /// model expects known=1, hole=0 → `[mask - 0.5, img * mask]` zeros the hole.
    private static func makeInputArray(image: UIImage, holeMask: UIImage) -> MLMultiArray? {
        let side = modelResolution
        guard let multiArray = try? MLMultiArray(
            shape: [1, 4, NSNumber(value: side), NSNumber(value: side)],
            dataType: .float32
        ),
              let rgba = rgbaPixels(from: image),
              let maskGray = grayPixels(from: holeMask),
              rgba.width == side, rgba.height == side,
              maskGray.width == side, maskGray.height == side else { return nil }

        let ptr = multiArray.dataPointer.bindMemory(to: Float32.self, capacity: multiArray.count)
        let plane = side * side
        for i in 0..<plane {
            // Our hole masks are white-on-black; MI-GAN wants the opposite polarity.
            let hole = Float32(maskGray.bytes[i]) / 255.0
            let known = 1.0 - hole
            let bi = i * 4
            let r = Float32(rgba.bytes[bi]) * 2.0 / 255.0 - 1.0
            let g = Float32(rgba.bytes[bi + 1]) * 2.0 / 255.0 - 1.0
            let b = Float32(rgba.bytes[bi + 2]) * 2.0 / 255.0 - 1.0
            ptr[i] = known - 0.5
            ptr[plane + i] = r * known
            ptr[plane * 2 + i] = g * known
            ptr[plane * 3 + i] = b * known
        }
        return multiArray
    }

    private static func imageFromOutputArray(_ multiArray: MLMultiArray) -> UIImage? {
        let side = modelResolution
        let plane = side * side
        let ptr = multiArray.dataPointer.bindMemory(to: Float32.self, capacity: multiArray.count)
        var rgba = [UInt8](repeating: 255, count: plane * 4)
        for i in 0..<plane {
            let r = max(0, min(1, ptr[i] * 0.5 + 0.5))
            let g = max(0, min(1, ptr[plane + i] * 0.5 + 0.5))
            let b = max(0, min(1, ptr[plane * 2 + i] * 0.5 + 0.5))
            let o = i * 4
            rgba[o] = UInt8(r * 255)
            rgba[o + 1] = UInt8(g * 255)
            rgba[o + 2] = UInt8(b * 255)
            rgba[o + 3] = 255
        }
        return makeUIImage(fromRGBA: rgba, width: side, height: side)
    }

    // MARK: - Pixels (UIKit top-left, avoids CGContext Y-flip bugs)

    private struct PixelBuffer {
        let bytes: [UInt8]
        let width: Int
        let height: Int
    }

    private static func rgbaPixels(from image: UIImage) -> PixelBuffer? {
        let w = Int(image.size.width.rounded())
        let h = Int(image.size.height.rounded())
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Flip to UIKit top-left so mask/image line up with stroke coordinates.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(ctx)
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
            UIGraphicsPopContext()
            return true
        }
        guard ok else { return nil }
        return PixelBuffer(bytes: bytes, width: w, height: h)
    }

    private static func grayPixels(from image: UIImage) -> PixelBuffer? {
        guard let rgba = rgbaPixels(from: image) else { return nil }
        var gray = [UInt8](repeating: 0, count: rgba.width * rgba.height)
        for i in 0..<(rgba.width * rgba.height) {
            gray[i] = rgba.bytes[i * 4] // white hole → 255
        }
        return PixelBuffer(bytes: gray, width: rgba.width, height: rgba.height)
    }

    private static func makeUIImage(fromRGBA bytes: [UInt8], width: Int, height: Int) -> UIImage? {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    // MARK: - Geometry / compose

    private static func strokeCropRect(
        points: [CGPoint],
        brushDiameter: CGFloat,
        canvasSize: CGSize
    ) -> CGRect {
        let radius = brushDiameter / 2
        let padding = max(brushDiameter * 1.1, 16)
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
        rect = rect.intersection(canvas).integral
        if rect.width < minimumCropSide {
            rect.size.width = min(canvas.width, minimumCropSide)
            rect.origin.x = min(max(rect.origin.x, 0), canvas.width - rect.width)
        }
        if rect.height < minimumCropSide {
            rect.size.height = min(canvas.height, minimumCropSide)
            rect.origin.y = min(max(rect.origin.y, 0), canvas.height - rect.height)
        }
        return rect
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

    private static func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        ImageLoader.renderOpaque(size: size, scale: 1) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        } ?? image
    }

    private static func paste(patch: UIImage, into base: UIImage, at rect: CGRect) -> UIImage {
        ImageLoader.renderOpaque(size: base.size, scale: base.scale) { _ in
            base.draw(in: CGRect(origin: .zero, size: base.size))
            patch.draw(in: rect)
        } ?? base
    }

    /// Light feather for photo textures (flat white UI uses opaque flat fill instead).
    private static func softBlendHole(original: UIImage, filled: UIImage, holeMask: UIImage) -> UIImage? {
        guard let o = CIImage(image: original),
              let f = CIImage(image: filled),
              let m = CIImage(image: holeMask) else { return nil }

        let extent = o.extent
        let fg = f.transformed(by: CGAffineTransform(
            translationX: -f.extent.origin.x, y: -f.extent.origin.y
        )).cropped(to: extent)
        var mk = m.transformed(by: CGAffineTransform(
            translationX: -m.extent.origin.x, y: -m.extent.origin.y
        )).cropped(to: extent)

        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(mk, forKey: kCIInputImageKey)
            blur.setValue(0.8, forKey: kCIInputRadiusKey)
            if let blurred = blur.outputImage?.cropped(to: extent) {
                mk = blurred
            }
        }

        guard let filter = CIFilter(name: "CIBlendWithMask") else { return nil }
        filter.setValue(fg, forKey: kCIInputImageKey)
        filter.setValue(o, forKey: kCIInputBackgroundImageKey)
        filter.setValue(mk, forKey: kCIInputMaskImageKey)
        guard let out = filter.outputImage?.cropped(to: extent),
              let cg = ciContext.createCGImage(out, from: extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

}
