import UIKit
import UnragerKit

/// Bridges the server's `/api/session` to the app's local state so a source /
/// feed-mode / filter choice persists across launches and is shared with the
/// TUI (the server is the single source of truth). On launch `restore()` pulls
/// the session and applies `filter_enabled`, `feed_mode` (the Originals toggle)
/// and a canonical light/dark `theme`; thereafter the feed and Settings call the
/// `patch*` helpers on every relevant change.
///
/// `theme` is restored defensively but never patched from iOS: the app's
/// appearance axis (system/light/dark) is coarser than the TUI's named themes,
/// so writing it back would clobber a rich TUI theme on the shared server.
@MainActor
enum SessionSync {
    private static let api = AppEnvironment.shared.api

    /// Posted once the server session has been applied, carrying the restored
    /// Home feed state so the active Home feed can switch to it. Carries
    /// `following` and `originals` flags in `userInfo`.
    static let didRestoreHome = Notification.Name("unrager.sessionDidRestoreHome")

    static func restore(applyAppearance: @escaping @MainActor (AppearanceMode) -> Void) {
        Task {
            guard let state = try? await api.session() else { return }
            AppSettings.filterEnabled = state.filterEnabled
            let originals = state.feedMode == .originals
            if let appearance = appearance(from: state.theme), AppSettings.appearance == .system {
                AppSettings.appearance = appearance
                applyAppearance(appearance)
            }
            if case let .home(following) = state.currentSource {
                NotificationCenter.default.post(
                    name: didRestoreHome, object: nil,
                    userInfo: ["following": following, "originals": originals])
            } else if originals {
                NotificationCenter.default.post(
                    name: didRestoreHome, object: nil,
                    userInfo: ["following": false, "originals": true])
            }
            AppLogger.shared.info("session restored: filter=\(state.filterEnabled) originals=\(originals)", category: .app)
        }
    }

    static func patchSource(_ source: SourceKind) {
        patch(SessionPatch(currentSource: source))
    }

    static func patchFeedMode(originals: Bool) {
        patch(SessionPatch(feedMode: originals ? .originals : .all))
    }

    static func patchFilterEnabled(_ enabled: Bool) {
        patch(SessionPatch(filterEnabled: enabled))
    }

    private static func patch(_ patch: SessionPatch) {
        Task {
            do {
                _ = try await api.patchSession(patch)
            } catch {
                AppLogger.shared.warn("session patch failed: \(error)", category: .app)
            }
        }
    }

    /// Maps the TUI's canonical theme names to a light/dark appearance; anything
    /// else (named themes) leaves the app on its own setting.
    private static func appearance(from theme: String?) -> AppearanceMode? {
        switch theme?.lowercased() {
        case "x-light", "light": return .light
        case "x-dark", "dark", "midnight": return .dark
        default: return nil
        }
    }
}
