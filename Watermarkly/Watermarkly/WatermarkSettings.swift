import UIKit

enum WatermarkMode: Int, CaseIterable {
    case tiled
    case corner
    case card
    case retouch

    var title: String {
        switch self {
        case .tiled: return "Tiled"
        case .corner: return "Corner"
        case .card: return "Card"
        case .retouch: return "Retouch"
        }
    }
}

enum CornerPosition: Int, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight, center

    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .center: return "Center"
        }
    }
}

enum DeviceFrameTemplate: Int, CaseIterable {
    case iPhone
    case iPad
    case mac

    var title: String {
        switch self {
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        case .mac: return "Mac"
        }
    }

    /// Asset name once real PNG templates are added to Assets.xcassets.
    var assetName: String {
        switch self {
        case .iPhone: return "frame_iphone"
        case .iPad: return "frame_ipad"
        case .mac: return "frame_mac"
        }
    }

    /// Screen inset within the template canvas (normalized 0–1).
    var screenRect: CGRect {
        switch self {
        case .iPhone: return CGRect(x: 0.08, y: 0.06, width: 0.84, height: 0.88)
        case .iPad: return CGRect(x: 0.06, y: 0.05, width: 0.88, height: 0.90)
        case .mac: return CGRect(x: 0.10, y: 0.08, width: 0.80, height: 0.72)
        }
    }

    var canvasSize: CGSize {
        switch self {
        case .iPhone: return CGSize(width: 900, height: 1800)
        case .iPad: return CGSize(width: 1400, height: 1800)
        case .mac: return CGSize(width: 1600, height: 1200)
        }
    }
}

struct WatermarkSettings {
    var mode: WatermarkMode = .tiled
    var text: String = "Watermarkly"
    var tiledLogoImage: UIImage?
    var cornerLogoImage: UIImage?

    // Tiled
    var opacity: CGFloat = 0.4
    var rotation: CGFloat = -45
    var spacing: CGFloat = 50
    var fontSize: CGFloat = 36
    var tiledScale: CGFloat = 1.0

    // Corner
    var cornerPosition: CornerPosition = .bottomRight
    var cornerScale: CGFloat = 0.15
    var cornerPadding: CGFloat = 24

    // Photo card — border is a percentage of photo width/height (2–18%).
    var frameBorderPercent: CGFloat = 8
    var frameShowsCaption: Bool = true

    // Retouch
    var retouchBrushSize: CGFloat = 40
    var retouchBrushColorIndex: Int = 0
    var deviceTemplate: DeviceFrameTemplate = .iPhone

    func logo(for mode: WatermarkMode) -> UIImage? {
        switch mode {
        case .tiled: return tiledLogoImage
        case .corner: return cornerLogoImage
        case .card: return nil
        case .retouch: return nil
        }
    }

    mutating func setLogo(_ image: UIImage?, for mode: WatermarkMode) {
        switch mode {
        case .tiled: tiledLogoImage = image
        case .corner: cornerLogoImage = image
        case .card: break
        case .retouch: break
        }
    }
}
