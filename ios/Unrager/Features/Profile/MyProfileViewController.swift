import UIKit
import UnragerKit

/// The signed-in user's profile as a tab root. The handle isn't known until a
/// `whoami` round-trip resolves, so this shows a spinner, then embeds a
/// `ProfileViewController` for the resolved handle as a child. Retries on
/// failure via an empty-state button. The embedded profile drives this
/// screen's status bar, title and scroll edge, since this is the screen the
/// navigation stack shows.
final class MyProfileViewController: UIViewController {
    private let skeleton = ProfileSkeletonView()
    private let emptyState = EmptyStateView()
    private var profile: ProfileViewController?

    override var childForStatusBarStyle: UIViewController? { profile }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Profile"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .never

        view.addManaged(skeleton)
        skeleton.pinEdges(to: view)
        skeleton.isHidden = true
        emptyState.isHidden = true
        emptyState.onRetry = { [weak self] in self?.resolve() }
        view.addManaged(emptyState)
        emptyState.pinEdges(toSafeAreaOf: view)
        resolve()
    }

    private func resolve() {
        guard profile == nil else { return }
        emptyState.isHidden = true
        if let remembered = AppEnvironment.shared.rememberedHandle {
            embed(handle: remembered)
            verify(handle: remembered)
            return
        }
        skeleton.isHidden = false
        Task {
            do {
                let me = try await AppEnvironment.shared.api.whoami()
                embed(handle: me.handle)
            } catch {
                skeleton.isHidden = true
                emptyState.isHidden = false
                emptyState.show(symbol: "person.crop.circle.badge.exclamationmark",
                                title: "Couldn't load profile", subtitle: error.localizedDescription, showRetry: true)
                AppLogger.shared.warn("my-profile whoami failed: \(error)", category: .profile)
            }
        }
    }

    /// Checks the remembered handle against the server's answer in the
    /// background, and swaps to the right profile if the account has changed.
    private func verify(handle: String) {
        Task {
            guard let me = await AppEnvironment.shared.whoami(),
                  me.handle.caseInsensitiveCompare(handle) != .orderedSame else { return }
            AppLogger.shared.info("signed-in account changed from @\(handle) to @\(me.handle)", category: .profile)
            if let profile {
                profile.willMove(toParent: nil)
                profile.view.removeFromSuperview()
                profile.removeFromParent()
                self.profile = nil
            }
            embed(handle: me.handle)
        }
    }

    private func embed(handle: String) {
        let child = ProfileViewController(handle: handle)
        addChild(child)
        view.addManaged(child.view)
        child.view.pinEdges(to: view)
        child.didMove(toParent: self)
        profile = child
        skeleton.isHidden = true
        setNeedsStatusBarAppearanceUpdate()
    }
}
