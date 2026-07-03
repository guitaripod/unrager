import AppKit
import UnragerKit

/// A user's profile: a header (avatar / name / counts / Brief) above their
/// timeline. Reuses `FeedViewController` for the timeline machinery.
@MainActor
final class ProfileViewController: FeedViewController {
    private let handle: String
    private let profileHeader = ProfileHeaderView()

    init(handle: String) {
        self.handle = handle
        super.init(viewModel: TimelineViewModel(source: .user(handle: handle)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "@\(handle)"
        profileHeader.onBrief = { [weak self] in self?.presentBrief() }
        headerView = profileHeader
        loadProfile()
    }

    private func loadProfile() {
        Task {
            do {
                let profile = try await api.profile(handle: handle)
                profileHeader.configure(with: profile.user, imagesEnabled: AppSettings.imagesEnabled)
                loadFlag(for: profile.user)
            } catch {
                AppLogger.shared.warn("profile load failed: \(error)", category: .profile)
            }
        }
    }

    /// Resolves the profiled user's country flag and shows the header's
    /// "based in <country>" line, mirroring the TUI's profile header.
    private func loadFlag(for user: User) {
        AppEnvironment.shared.flags.resolve(restID: user.restID, screenName: user.handle) {
            [weak profileHeader] resolved in
            profileHeader?.setBasedIn(flag: resolved.flag, country: resolved.country)
        }
    }

    private func presentBrief() {
        let api = api
        let handle = handle
        navigator?.presentStream(title: "Brief on @\(handle)") {
            api.briefStream(handle: handle)
        }
    }
}
