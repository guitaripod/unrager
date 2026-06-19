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
            } catch {
                AppLogger.shared.warn("profile load failed: \(error)", category: .profile)
            }
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
