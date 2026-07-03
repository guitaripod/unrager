import Foundation

/// One turn of an ask conversation. Roles match Ollama's chat roles and the
/// server's `AskRole` wire enum.
public enum AskRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct AskTurn: Codable, Sendable, Equatable {
    public let role: AskRole
    public let text: String

    public init(role: AskRole, text: String) {
        self.role = role
        self.text = text
    }
}

/// A lightweight tweet reference carried as ask context — only what the
/// server's prompt builder needs.
public struct AskContextEntry: Codable, Sendable, Equatable {
    public let handle: String
    public let text: String

    public init(handle: String, text: String) {
        self.handle = handle
        self.text = text
    }

    public init(tweet: Tweet) {
        self.init(handle: tweet.author.handle, text: tweet.text)
    }
}

/// Request body for `POST /api/sse/ask` — the conversational ask stream with
/// thread context, mirroring the TUI's ask view. `turns` is the whole
/// conversation oldest-first and must end with the user's current question;
/// `ancestors` are root-first.
public struct AskRequest: Encodable, Sendable, Equatable {
    public let tweetID: String
    public let turns: [AskTurn]
    public let ancestors: [AskContextEntry]
    public let siblings: [AskContextEntry]
    public let replies: [AskContextEntry]

    enum CodingKeys: String, CodingKey {
        case tweetID = "tweet_id"
        case turns, ancestors, siblings, replies
    }

    public init(tweetID: String, turns: [AskTurn],
                ancestors: [AskContextEntry] = [], siblings: [AskContextEntry] = [],
                replies: [AskContextEntry] = []) {
        self.tweetID = tweetID
        self.turns = turns
        self.ancestors = ancestors
        self.siblings = siblings
        self.replies = replies
    }
}
