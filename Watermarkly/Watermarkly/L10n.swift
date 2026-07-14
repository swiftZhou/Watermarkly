import Foundation

/// Localized UI strings. Keys match `Localizable.xcstrings`.
enum L10n {
    static func tr(_ key: String.LocalizationValue) -> String {
        String(localized: key)
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        let template = String(localized: String.LocalizationValue(key))
        return String(format: template, locale: .current, arguments: args)
    }

    // MARK: - Home

    static var appName: String { tr("Watermarkly") }
    static var homeSubtitle: String { tr("Batch protect your product photos") }
    static var selectPhotos: String { tr("Select Photos") }
    static var unlimitedSavesUnlocked: String { tr("Unlimited saves unlocked") }
    static func freeSavesRemaining(_ count: Int) -> String {
        format("%lld free saves remaining · up to 3 photos", count)
    }
    static var unlock: String { tr("Unlock") }
    static var unableToLoadPhotos: String { tr("Unable to Load Photos") }
    static var trySelectingDifferentImages: String { tr("Please try selecting different images.") }
    static var ok: String { tr("OK") }

    // MARK: - Modes

    static var modeTiled: String { tr("Tiled") }
    static var modeCorner: String { tr("Corner") }
    static var modeCard: String { tr("Card") }
    static var modeRetouch: String { tr("Retouch") }

    // MARK: - Edit

    static var edit: String { tr("Edit") }
    static var previous: String { tr("Previous") }
    static var next: String { tr("Next") }
    static var saveAll: String { tr("Save All") }
    static var undo: String { tr("Undo") }
    static var watermarkTextPlaceholder: String { tr("Watermark text") }
    static var captionOnCardPlaceholder: String { tr("Caption on card") }
    static var chooseLogo: String { tr("Choose Logo") }
    static var clearLogo: String { tr("Clear Logo") }
    static var opacity: String { tr("Opacity") }
    static var rotation: String { tr("Rotation") }
    static var spacing: String { tr("Spacing") }
    static var size: String { tr("Size") }
    static var borderWidth: String { tr("Border Width") }
    static var brushSize: String { tr("Brush Size") }
    static var brushColor: String { tr("Brush Color") }
    static var showCaption: String { tr("Show Caption") }
    static var deviceTemplate: String { tr("Device Template") }
    static var position: String { tr("Position") }
    static var cornerTL: String { tr("TL") }
    static var cornerTR: String { tr("TR") }
    static var cornerBL: String { tr("BL") }
    static var cornerBR: String { tr("BR") }
    static var cornerC: String { tr("C") }
    static func photoPageRetouch(index: Int, total: Int) -> String {
        format("Photo %lld of %lld · pinch to zoom", index, total)
    }
    static func photoPageScroll(index: Int, total: Int) -> String {
        format("Photo %lld of %lld · scroll horizontally · pinch to zoom", index, total)
    }
    static var photoPageSingle: String { tr("Photo 1 of 1 · pinch to zoom") }
    static var saved: String { tr("Saved") }
    static var saveFailed: String { tr("Save Failed") }

    // MARK: - Purchase

    static var unlockTitle: String { tr("Unlock Watermarkly") }
    static var unlockSubtitle: String { tr("One-time purchase. No subscription.") }
    static var purchaseBenefits: String { tr("purchase_benefits") }
    static var restorePurchases: String { tr("Restore Purchases") }
    static func unlockForPrice(_ price: String) -> String {
        format("Unlock for %@", price)
    }
    static var noPreviousPurchase: String { tr("No previous purchase found for this Apple ID.") }
    static var purchaseError: String { tr("Purchase Error") }
    static var unlockProductUnavailable: String {
        tr("The unlock product is not available. Please try again later.")
    }

    // MARK: - Save

    static var savingPhotos: String { tr("Saving Photos") }
    static var preparing: String { tr("Preparing…") }
    static func renderingProgress(current: Int, total: Int) -> String {
        format("Rendering %lld of %lld…", current, total)
    }
    static var writingToPhotoLibrary: String { tr("Writing to photo library…") }
    static var allowPhotoLibraryAccess: String {
        tr("Please allow photo library access in Settings.")
    }
    static func photosSaved(_ count: Int) -> String {
        format("%lld photo(s) saved to your library.", count)
    }
    static var unableToSavePhotos: String { tr("Unable to save photos.") }

    // MARK: - Legal

    static var privacyPolicy: String { tr("Privacy Policy") }
    static var support: String { tr("Support") }
}
