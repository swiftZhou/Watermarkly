import Foundation
import StoreKit

@MainActor
protocol StoreManagerDelegate: AnyObject {
    func storeManagerDidUpdateUnlockStatus(_ manager: StoreManager)
}

@MainActor
final class StoreManager {
    static let shared = StoreManager()
    static let unlockProductID = "com.zhouhai.Watermarkly.unlock"

    weak var delegate: StoreManagerDelegate?

    private(set) var unlockProduct: Product?
    private(set) var isLoading = false
    private var transactionListener: Task<Void, Never>?

    private init() {}

    func start() {
        transactionListener?.cancel()
        transactionListener = Task { await listenForTransactions() }
        Task { await loadProducts() }
        Task { await syncEntitlements() }
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let products = try await Product.products(for: [Self.unlockProductID])
            unlockProduct = products.first
        } catch {
            unlockProduct = nil
        }
    }

    func purchaseUnlock() async throws {
        guard let product = unlockProduct else {
            throw StoreError.productUnavailable
        }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            TrialManager.shared.markUnlocked()
            delegate?.storeManagerDidUpdateUnlockStatus(self)
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func restorePurchases() async throws {
        try await AppStore.sync()
        await syncEntitlements()
    }

    var displayPrice: String {
        unlockProduct?.displayPrice ?? "$2.99"
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            guard let transaction = try? checkVerified(result) else { continue }
            if transaction.productID == Self.unlockProductID {
                TrialManager.shared.markUnlocked()
                delegate?.storeManagerDidUpdateUnlockStatus(self)
            }
            await transaction.finish()
        }
    }

    private func syncEntitlements() async {
        var unlocked = TrialManager.shared.isUnlocked
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if transaction.productID == Self.unlockProductID {
                unlocked = true
            }
        }
        if unlocked {
            TrialManager.shared.markUnlocked()
            delegate?.storeManagerDidUpdateUnlockStatus(self)
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }
}

enum StoreError: LocalizedError {
    case productUnavailable

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            return L10n.unlockProductUnavailable
        }
    }
}
