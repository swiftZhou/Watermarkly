import UIKit

enum AppTheme {
    static let background = UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1) // #F2F2F7
    static let accent = UIColor(red: 0, green: 0.478, blue: 1, alpha: 1) // #007AFF
    static let cornerRadius: CGFloat = 10

    /// Fixed dark text for the always-light app chrome (independent of system Dark Mode).
    static let primaryText = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    static let secondaryText = UIColor(red: 0.24, green: 0.24, blue: 0.26, alpha: 0.72)
    static let fieldBackground = UIColor.white
    static let fieldBorder = UIColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1)

    static func applyNavigationBarAppearance(to navigationController: UINavigationController?) {
        guard let navigationController else { return }
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = background
        appearance.titleTextAttributes = [.foregroundColor: primaryText]
        appearance.largeTitleTextAttributes = [.foregroundColor: primaryText]

        let bar = navigationController.navigationBar
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
        bar.tintColor = accent
    }
}
