import Foundation

/// Unsent composer text the user chose to keep, one draft per place it was
/// written for: a new post, a reply to a given post, or a quote of one. Only
/// the text is kept; attached photos are not. The newest `capacity` drafts
/// survive, so replies abandoned long ago don't pile up.
struct ComposeDraftStore {
    static var shared: ComposeDraftStore { ComposeDraftStore(defaults: .standard) }
    static let capacity = 20

    private static let key = "unrager.composeDrafts"

    private struct Entry: Codable {
        let slot: String
        let text: String
    }

    let defaults: UserDefaults

    /// Where a draft belongs: "new", "reply-<id>" or "quote-<id>".
    static func slot(for mode: ComposeViewController.Mode) -> String {
        switch mode {
        case .new: return "new"
        case let .reply(tweet): return "reply-\(tweet.restID)"
        case let .quote(tweet): return "quote-\(tweet.restID)"
        }
    }

    func draft(for slot: String) -> String? {
        entries().last { $0.slot == slot }?.text
    }

    func save(_ text: String, for slot: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(slot); return }
        let kept = entries().filter { $0.slot != slot } + [Entry(slot: slot, text: text)]
        write(Array(kept.suffix(Self.capacity)))
    }

    func clear(_ slot: String) {
        let current = entries()
        let kept = current.filter { $0.slot != slot }
        guard kept.count != current.count else { return }
        write(kept)
    }

    private func entries() -> [Entry] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func write(_ entries: [Entry]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
