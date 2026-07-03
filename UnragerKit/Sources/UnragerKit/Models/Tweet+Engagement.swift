import Foundation

extension Tweet {
    /// A copy with the viewer's repost state and repost count replaced — the
    /// write-back after a confirmed repost/undo, mirroring `withLike` so a
    /// stored model (and any cell reconfigured from it) reflects the
    /// engagement instead of reverting.
    public func withRetweet(retweeted: Bool, retweetCount: Int) -> Tweet {
        copyReplacing([
            CodingKeys.retweeted.rawValue: retweeted,
            CodingKeys.retweetCount.rawValue: max(0, retweetCount),
        ])
    }

    /// A copy toggled to the given repost state with the count adjusted by one
    /// (never below zero), or `nil` when the tweet is already in that state —
    /// the same duplicate-confirmation guard as `togglingLike`, so a repeated
    /// confirmation can't double-count.
    public func togglingRetweet(to retweeted: Bool) -> Tweet? {
        guard self.retweeted != retweeted else { return nil }
        return withRetweet(retweeted: retweeted, retweetCount: retweetCount + (retweeted ? 1 : -1))
    }

    /// A copy with the viewer's bookmark state and bookmark count replaced —
    /// the write-back after a confirmed bookmark/unbookmark.
    public func withBookmark(bookmarked: Bool, bookmarkCount: Int) -> Tweet {
        copyReplacing([
            CodingKeys.bookmarked.rawValue: bookmarked,
            CodingKeys.bookmarkCount.rawValue: max(0, bookmarkCount),
        ])
    }

    /// A copy toggled to the given bookmark state with the count adjusted by
    /// one (never below zero), or `nil` when the tweet is already in that
    /// state.
    public func togglingBookmark(to bookmarked: Bool) -> Tweet? {
        guard self.bookmarked != bookmarked else { return nil }
        return withBookmark(bookmarked: bookmarked, bookmarkCount: bookmarkCount + (bookmarked ? 1 : -1))
    }

    /// Rebuilds the tweet with the given wire fields replaced, via a JSON
    /// round-trip: `Tweet`'s stored properties are immutable and its copying
    /// initializer is private to `Tweet.swift`, so write-backs added in this
    /// extension clone through the public `Codable` conformance instead
    /// (`UnragerJSON`'s encoder and decoder share one date dialect, so the
    /// trip is lossless for display purposes). Falls back to `self` when the
    /// round-trip fails — impossible for a value that itself decoded from
    /// this dialect, but safer than trapping.
    private func copyReplacing(_ overrides: [String: Any]) -> Tweet {
        guard let data = try? UnragerJSON.encoder.encode(self),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return self }
        for (key, value) in overrides { object[key] = value }
        guard let mutated = try? JSONSerialization.data(withJSONObject: object),
              let tweet = try? UnragerJSON.decoder.decode(Tweet.self, from: mutated)
        else { return self }
        return tweet
    }
}
