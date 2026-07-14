import UIKit
import ImageIO
import UniformTypeIdentifiers

enum ImageLoader {

    /// Decode and optionally downsample image data to avoid memory spikes from full-resolution photos.
    static func image(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    static func downsample(_ image: UIImage, maxPixelSize: CGFloat) -> UIImage {
        guard maxPixelSize > 0 else { return normalized(image) }
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let maxSide = max(pixelWidth, pixelHeight)
        guard maxSide > maxPixelSize, maxSide > 0 else { return normalized(image) }

        let ratio = maxPixelSize / maxSide
        let newSize = CGSize(width: pixelWidth * ratio, height: pixelHeight * ratio)
        return renderOpaque(size: newSize, scale: 1) { _ in
            normalized(image).draw(in: CGRect(origin: .zero, size: newSize))
        } ?? normalized(image)
    }

    /// Downsample so the image fits inside `bounds` at `screenScale` (for live slider preview).
    static func downsampleToFit(_ image: UIImage, in bounds: CGSize, screenScale: CGFloat) -> UIImage {
        guard bounds.width > 0, bounds.height > 0 else { return normalized(image) }
        let maxPixelSize = max(bounds.width, bounds.height) * max(screenScale, 1)
        return downsample(image, maxPixelSize: maxPixelSize)
    }

    static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        return renderOpaque(size: image.size, scale: image.scale) { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        } ?? image
    }

    /// Renders into an RGB bitmap without alpha to avoid PhotoKit / ImageIO alpha warnings and extra memory.
    static func renderOpaque(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = scale

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cgContext = context.cgContext
            // Opaque bitmaps default to black; callers may rely on a white base (e.g. photo frame).
            UIColor.white.setFill()
            cgContext.fill(CGRect(origin: .zero, size: size))
            draw(cgContext)
        }
    }

    /// Renders into a bitmap with alpha for watermark overlay layers.
    static func renderTransparent(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> UIImage? {
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.clear(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        UIGraphicsPushContext(context)
        draw(context)
        UIGraphicsPopContext()

        guard let cgImage = context.makeImage() else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }

    /// Ensures exported images use RGB without alpha before writing to the photo library.
    static func flattenForExport(_ image: UIImage) -> UIImage {
        if let cgImage = image.cgImage {
            let alpha = cgImage.alphaInfo
            let hasMeaningfulAlpha = alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast
            if !hasMeaningfulAlpha {
                return image
            }
        }
        return renderOpaque(size: image.size, scale: image.scale) { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        } ?? image
    }

    private static func thumbnail(from source: CGImageSource, maxPixelSize: CGFloat) -> UIImage? {
        let clampedMax = clampedThumbnailSize(for: source, requested: maxPixelSize)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: clampedMax
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func clampedThumbnailSize(for source: CGImageSource, requested: CGFloat) -> CGFloat {
        guard requested > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return requested
        }

        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let sourceMax = max(width, height)
        guard sourceMax > 0 else { return requested }
        return min(requested, sourceMax)
    }
}

enum ImageLimits {
    static let pickerMaxPixelSize: CGFloat = 4032
    /// Editor preview resolution (spacing drag + settled preview — must stay the same).
    static let previewMaxPixelSize: CGFloat = 1200
    /// LaMa working resolution while editing (pre-resize before Core ML's 800×800 input).
    static let retouchPreviewInpaintMaxPixelSize: CGFloat = 384
    /// LaMa working resolution when exporting retouched photos.
    static let retouchExportInpaintMaxPixelSize: CGFloat = 800
}
