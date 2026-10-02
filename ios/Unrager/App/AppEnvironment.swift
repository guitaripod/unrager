import UIKit
import UnragerKit

/// Process-wide singletons. The `APIClient` reads the server URL from
/// `AppSettings` on every request, so changing the address in Settings takes
/// effect immediately with no rebuild of the client.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let api: APIClient
    /// Session-scoped author country-flag resolver shared by every feed,
    /// thread and profile screen, so an author resolves at most once per run.
    let flags: AuthorFlags
    let log = AppLogger.shared

    /// The signed-in account, fetched once and cached. Lets surfaces like the
    /// tweet context menu decide "is this my tweet?" without re-hitting `whoami`.
    private var cachedWhoami: Whoami?
    private var whoamiTask: Task<Whoami?, Never>?

    private init() {
        api = APIClient(baseURL: { AppSettings.serverURL })
        flags = AuthorFlags(api: api)
        NotificationCenter.default.addObserver(
            forName: AppSettings.serverURLDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forgetAccount() }
        }
    }

    /// A new server may hold a different X session, so the cached account is
    /// fetched again on next use.
    private func forgetAccount() {
        cachedWhoami = nil
        whoamiTask = nil
    }

    /// The signed-in handle if already known, else nil. Non-blocking — kicks off
    /// a background fetch so the next caller resolves synchronously.
    var currentHandle: String? {
        if let cachedWhoami { return cachedWhoami.handle }
        prefetchWhoami()
        return rememberedHandle
    }

    private static var handleKey: String { "unrager.cache.handle.\(AppSettings.serverURLString)" }

    /// The handle this server last said was signed in, kept across launches so
    /// the profile tab can open at once instead of waiting on `whoami`. A hint
    /// only: the real answer replaces it as soon as it arrives.
    var rememberedHandle: String? {
        UserDefaults.standard.string(forKey: Self.handleKey)
    }

    private func remember(_ account: Whoami?) {
        guard let account else { return }
        UserDefaults.standard.set(account.handle, forKey: Self.handleKey)
    }

    func prefetchWhoami() {
        guard cachedWhoami == nil, whoamiTask == nil else { return }
        whoamiTask = Task { [api] in try? await api.whoami() }
        Task { [weak self] in
            let result = await self?.whoamiTask?.value
            self?.cachedWhoami = result ?? nil
            self?.remember(result ?? nil)
            self?.whoamiTask = nil
        }
    }

    /// Awaits the signed-in identity, fetching once and caching.
    func whoami() async -> Whoami? {
        if let cachedWhoami { return cachedWhoami }
        let result = try? await api.whoami()
        if let result {
            cachedWhoami = result
            remember(result)
        }
        return result
    }
}
