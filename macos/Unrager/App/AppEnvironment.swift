import AppKit
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
    /// thread analytics block decide "is this my tweet?" without re-hitting
    /// `whoami` on every open.
    private var cachedWhoami: Whoami?
    private var whoamiTask: Task<Whoami?, Never>?

    private init() {
        api = APIClient(baseURL: { AppSettings.serverURL })
        flags = AuthorFlags(api: api)
    }

    /// The signed-in handle if already known, else nil. Non-blocking — kicks off
    /// a background fetch so the next caller resolves synchronously.
    var currentHandle: String? {
        if let cachedWhoami { return cachedWhoami.handle }
        prefetchWhoami()
        return nil
    }

    func prefetchWhoami() {
        guard cachedWhoami == nil, whoamiTask == nil else { return }
        whoamiTask = Task { [api] in try? await api.whoami() }
        Task { [weak self] in
            let result = await self?.whoamiTask?.value
            self?.cachedWhoami = result ?? nil
            self?.whoamiTask = nil
        }
    }

    /// Awaits the signed-in identity, fetching once and caching.
    func whoami() async -> Whoami? {
        if let cachedWhoami { return cachedWhoami }
        let result = try? await api.whoami()
        if let result { cachedWhoami = result }
        return result
    }
}
