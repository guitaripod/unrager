import UIKit
import UnragerKit

/// Bridges the server's `/api/session` to the app's local state. On launch
/// `restore()` pulls the session and applies `filter_enabled`; thereafter
/// Settings and the feed call the `patch*` helpers on every change.
///
/// Appearance (system/light/dark) and Home feed mode are deliberately NOT
/// restored from the server — they're local choices (`AppSettings.appearance`
/// defaults to system, `ClientSettings` for feed mode), so the device's own
/// setting is authoritative and the shared TUI theme can't force the app dark.
@MainActor
enum SessionSync {
    private static let api = AppEnvironment.shared.api

    private static var restoreTask: Task<Void, Never>?

    static func restore() {
        restoreTask = Task {
            guard let state = try? await api.session(), !Task.isCancelled else { return }
            AppSettings.filterEnabled = state.filterEnabled
            AppLogger.shared.info("session restored: filter=\(state.filterEnabled)", category: .app)
        }
    }

    /// Waits (at most `timeout`) for the launch-time `restore()`, so the first
    /// Home load judges with the server's filter setting rather than the one
    /// the app last saved. Returns at once when nothing is restoring.
    static func awaitRestore(timeout: Duration = .seconds(2)) async {
        guard let restoreTask else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await restoreTask.value }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    static func patchSource(_ source: SourceKind) {
        patch(SessionPatch(currentSource: source))
    }

    static func patchFeedMode(originals: Bool) {
        patch(SessionPatch(feedMode: originals ? .originals : .all))
    }

    static func patchFilterEnabled(_ enabled: Bool) {
        restoreTask?.cancel()
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
}
