import UIKit

enum AppTheme {
    /// Soft aqua wash aligned with the app icon light field.
    static let background = UIColor(red: 0.929, green: 0.969, blue: 0.969, alpha: 1) // #EDF7F7
    /// Logo teal — sampled from App Icon mid/deep waves (#0F8E95).
    static let accent = UIColor(red: 0.059, green: 0.557, blue: 0.584, alpha: 1) // #0F8E95
    static let cornerRadius: CGFloat = 10

    /// Fixed dark text for the always-light app chrome (independent of system Dark Mode).
    static let primaryText = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    static let secondaryText = UIColor(red: 0.24, green: 0.24, blue: 0.26, alpha: 0.72)
    static let fieldBackground = UIColor.white
    static let fieldBorder = UIColor(red: 0.75, green: 0.82, blue: 0.82, alpha: 1)

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
