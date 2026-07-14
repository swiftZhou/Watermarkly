import Foundation

final class TrialManager {
    static let shared = TrialManager()

    /// Temporary dev switch — set to `false` before release.
    private let bypassPurchaseLimits = true

    private let usedCountKey = "freeTrialCount"
    private let unlockedKey = "isUnlocked"
    private let maxFreeTrials = 3
    private let freeSelectionLimit = 3

    private init() {}

    var remainingTrials: Int {
        if bypassPurchaseLimits { return Int.max }
        return max(0, maxFreeTrials - UserDefaults.standard.integer(forKey: usedCountKey))
    }

    var isUnlocked: Bool {
        if bypassPurchaseLimits { return true }
        return UserDefaults.standard.bool(forKey: unlockedKey)
    }

    var selectionLimit: Int {
        if bypassPurchaseLimits { return 0 }
        return isUnlocked ? 0 : freeSelectionLimit
    }

    func canSaveBatch() -> Bool {
        if bypassPurchaseLimits { return true }
        return isUnlocked || remainingTrials > 0
    }

    func consumeTrial() {
        if bypassPurchaseLimits { return }
        guard !isUnlocked else { return }
        let used = UserDefaults.standard.integer(forKey: usedCountKey)
        UserDefaults.standard.set(used + 1, forKey: usedCountKey)
    }

    func markUnlocked() {
        UserDefaults.standard.set(true, forKey: unlockedKey)
    }
}
