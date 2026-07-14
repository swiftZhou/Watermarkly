import UIKit
import StoreKit
import SafariServices

final class PurchaseViewController: UIViewController {

    var onUnlocked: (() -> Void)?

    private let iconView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 48, weight: .medium)
        let view = UIImageView(image: UIImage(systemName: "lock.open.fill", withConfiguration: config))
        view.tintColor = AppTheme.accent
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.unlockTitle
        label.font = .systemFont(ofSize: 28, weight: .bold)
        label.textColor = AppTheme.primaryText
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.text = L10n.unlockSubtitle
        label.font = .systemFont(ofSize: 16)
        label.textColor = AppTheme.secondaryText
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let benefitsLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 16)
        label.textColor = AppTheme.primaryText
        label.text = L10n.purchaseBenefits
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var purchaseButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .fixed
        config.background.cornerRadius = AppTheme.cornerRadius
        config.baseBackgroundColor = AppTheme.accent
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(purchaseTapped), for: .touchUpInside)
        return button
    }()

    private lazy var restoreButton: UIButton = {
        var config = UIButton.Configuration.bordered()
        config.title = L10n.restorePurchases
        config.baseForegroundColor = AppTheme.accent
        config.cornerStyle = .fixed
        config.background.cornerRadius = AppTheme.cornerRadius
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(restoreTapped), for: .touchUpInside)
        return button
    }()

    private lazy var privacyPolicyButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = AppTheme.secondaryText
        var title = AttributedString(L10n.privacyPolicy)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.underlineStyle = .single
        config.attributedTitle = title
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(privacyPolicyTapped), for: .touchUpInside)
        return button
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppTheme.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )
        setupLayout()
        updatePriceLabel()
        Task { await StoreManager.shared.loadProducts(); updatePriceLabel() }
    }

    private func setupLayout() {
        let stack = UIStackView(arrangedSubviews: [
            iconView, titleLabel, subtitleLabel, benefitsLabel,
            purchaseButton, restoreButton, privacyPolicyButton, activityIndicator
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.setCustomSpacing(24, after: benefitsLabel)
        stack.setCustomSpacing(8, after: restoreButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            iconView.heightAnchor.constraint(equalToConstant: 56)
        ])
        iconView.contentMode = .center
    }

    private func updatePriceLabel() {
        var config = purchaseButton.configuration ?? UIButton.Configuration.filled()
        config.title = L10n.unlockForPrice(StoreManager.shared.displayPrice)
        purchaseButton.configuration = config
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func purchaseTapped() {
        setLoading(true)
        Task {
            do {
                try await StoreManager.shared.purchaseUnlock()
                if TrialManager.shared.isUnlocked {
                    onUnlocked?()
                    dismiss(animated: true)
                }
            } catch {
                showError(error.localizedDescription)
            }
            setLoading(false)
        }
    }

    @objc private func restoreTapped() {
        setLoading(true)
        Task {
            do {
                try await StoreManager.shared.restorePurchases()
                if TrialManager.shared.isUnlocked {
                    onUnlocked?()
                    dismiss(animated: true)
                } else {
                    showError(L10n.noPreviousPurchase)
                }
            } catch {
                showError(error.localizedDescription)
            }
            setLoading(false)
        }
    }

    @objc private func privacyPolicyTapped() {
        let safari = SFSafariViewController(url: AppLinks.privacyPolicy)
        safari.preferredControlTintColor = AppTheme.accent
        present(safari, animated: true)
    }

    private func setLoading(_ loading: Bool) {
        purchaseButton.isEnabled = !loading
        restoreButton.isEnabled = !loading
        privacyPolicyButton.isEnabled = !loading
        loading ? activityIndicator.startAnimating() : activityIndicator.stopAnimating()
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: L10n.purchaseError, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.ok, style: .default))
        present(alert, animated: true)
    }
}
