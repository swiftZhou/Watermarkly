import UIKit
import SafariServices

enum PrivacyConsent {
    private static let agreedKey = "hasAgreedToPrivacyPolicy"

    static var hasAgreed: Bool {
        UserDefaults.standard.bool(forKey: agreedKey)
    }

    static func markAgreed() {
        UserDefaults.standard.set(true, forKey: agreedKey)
    }

    /// Presents a non-dismissible first-launch privacy agreement if needed.
    static func presentIfNeeded(from presenter: UIViewController) {
        guard !hasAgreed else { return }
        let vc = PrivacyConsentViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.isModalInPresentation = true
        presenter.present(vc, animated: true)
    }
}

final class PrivacyConsentViewController: UIViewController {
    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.privacyConsentTitle
        label.font = .systemFont(ofSize: 26, weight: .bold)
        label.textColor = AppTheme.primaryText
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let messageLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.privacyConsentMessage
        label.font = .systemFont(ofSize: 16)
        label.textColor = AppTheme.secondaryText
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var policyButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = AppTheme.accent
        var title = AttributedString(L10n.privacyPolicy)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.underlineStyle = .single
        config.attributedTitle = title
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(openPrivacyPolicy), for: .touchUpInside)
        return button
    }()

    private lazy var agreeButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = L10n.privacyConsentAgree
        config.baseBackgroundColor = AppTheme.accent
        config.baseForegroundColor = .white
        config.cornerStyle = .fixed
        config.background.cornerRadius = AppTheme.cornerRadius
        config.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(agreeTapped), for: .touchUpInside)
        return button
    }()

    private lazy var disagreeButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = L10n.privacyConsentDisagree
        config.baseForegroundColor = AppTheme.secondaryText
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(disagreeTapped), for: .touchUpInside)
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppTheme.background

        let stack = UIStackView(arrangedSubviews: [
            titleLabel, messageLabel, policyButton, agreeButton, disagreeButton
        ])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    @objc private func openPrivacyPolicy() {
        let safari = SFSafariViewController(url: AppLinks.privacyPolicy)
        safari.preferredControlTintColor = AppTheme.accent
        present(safari, animated: true)
    }

    @objc private func agreeTapped() {
        PrivacyConsent.markAgreed()
        dismiss(animated: true)
    }

    @objc private func disagreeTapped() {
        let alert = UIAlertController(
            title: L10n.privacyConsentDisagreeTitle,
            message: L10n.privacyConsentDisagreeMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
        present(alert, animated: true)
    }
}
