import UIKit
import UnragerKit

/// Bridges the server's `/api/session` to the app's local state so the filter
/// choice and theme persist across launches and stay shared with the TUI (the
/// server is the source of truth for those). On launch `restore()` pulls the
/// session and applies `filter_enabled` and a canonical light/dark `theme`;
/// thereafter Settings and the feed call the `patch*` helpers on every change.
///
/// The Home feed mode (Following + Originals) is the one exception: it's
/// restored from local `ClientSettings`, not the server, so the device's own
/// last choice is authoritative and can't be clobbered by a stale session.
/// iOS still *patches* feed mode so the TUI sees what the phone is doing.
///
/// `theme` is restored defensively but never patched from iOS: the app's
/// appearance axis (system/light/dark) is coarser than the TUI's named themes,
/// so writing it back would clobber a rich TUI theme on the shared server.
@MainActor
enum SessionSync {
    private static let api = AppEnvironment.shared.api

    static func restore(applyAppearance: @escaping @MainActor (AppearanceMode) -> Void) {
        Task {
            guard let state = try? await api.session() else { return }
            AppSettings.filterEnabled = state.filterEnabled
            if let appearance = appearance(from: state.theme), AppSettings.appearance == .system {
                AppSettings.appearance = appearance
                applyAppearance(appearance)
            }
            AppLogger.shared.info("session restored: filter=\(state.filterEnabled)", category: .app)
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
