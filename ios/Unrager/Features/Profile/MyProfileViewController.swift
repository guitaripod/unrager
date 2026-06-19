import UIKit
import UnragerKit

/// The signed-in user's profile as a tab root. The handle isn't known until a
/// `whoami` round-trip resolves, so this shows a spinner, then embeds a
/// `ProfileViewController` for the resolved handle as a child. Retries on
/// failure via an empty-state button.
final class MyProfileViewController: UIViewController {
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let emptyState = EmptyStateView()
    private var profile: ProfileViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Profile"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .never

        view.addManaged(loadingIndicator)
        emptyState.isHidden = true
        emptyState.onRetry = { [weak self] in self?.resolve() }
        view.addManaged(emptyState)
        emptyState.pinEdges(toSafeAreaOf: view)
        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        resolve()
    }

    private func resolve() {
        guard profile == nil else { return }
        emptyState.isHidden = true
        loadingIndicator.startAnimating()
        Task {
            do {
                let me = try await AppEnvironment.shared.api.whoami()
                loadingIndicator.stopAnimating()
                embed(handle: me.handle)
            } catch {
                loadingIndicator.stopAnimating()
                emptyState.isHidden = false
                emptyState.show(symbol: "person.crop.circle.badge.exclamationmark",
                                title: "Couldn't load profile", subtitle: error.localizedDescription, showRetry: true)
                AppLogger.shared.warn("my-profile whoami failed: \(error)", category: .profile)
            }
        }
    }

    private func embed(handle: String) {
        let child = ProfileViewController(handle: handle)
        addChild(child)
        view.addManaged(child.view)
        child.view.pinEdges(to: view)
        child.didMove(toParent: self)
        profile = child
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: DesignSystem.icon("safari"),
            primaryAction: UIAction { _ in
                if let url = URL(string: "https://x.com/\(handle)") { UIApplication.shared.open(url) }
            })
    }
}
