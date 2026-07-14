import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = .light
        let mainVC = MainViewController()
        let nav = UINavigationController(rootViewController: mainVC)
        nav.navigationBar.prefersLargeTitles = false
        AppTheme.applyNavigationBarAppearance(to: nav)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window

        // Defer StoreKit until UI is ready to reduce launch-time system service noise.
        Task { @MainActor in
            StoreManager.shared.start()
        }
    }
}
