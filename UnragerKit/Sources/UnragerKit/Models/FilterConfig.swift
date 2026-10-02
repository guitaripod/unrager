import Foundation

public struct OllamaConfig: Decodable, Sendable, Hashable {
    public let model: String
    public let host: String
}

/// How readily the filter hides a post (`strictness` in the server's
/// `filter.toml`). Changing it makes the server judge every post again.
public enum FilterStrictness: String, Codable, Sendable, CaseIterable {
    case relaxed
    case balanced
    case strict

    public var title: String {
        switch self {
        case .relaxed: return "Relaxed"
        case .balanced: return "Balanced"
        case .strict: return "Strict"
        }
    }

    public var summary: String {
        switch self {
        case .relaxed: return "Hides only posts clearly about one of your topics."
        case .balanced: return "Your topics plus the built-in rage-bait rules. A post the model isn't sure about stays."
        case .strict: return "Also hides posts by people known for a topic, and anything the model isn't sure about."
        }
    }
}

/// The rage-filter rubric from `GET /api/config/filter`.
public struct FilterConfig: Decodable, Sendable {
    public let dropTopics: [String]
    public let extraGuidance: String
    /// Nil when the server predates the strictness setting.
    public let strictness: FilterStrictness?
    /// The labels of the built-in rage-bait rules the server applies unless the
    /// filter is relaxed; empty on a server that doesn't report them.
    public let builtInRules: [String]
    public let ollama: OllamaConfig?

    enum CodingKeys: String, CodingKey {
        case dropTopics = "drop_topics"
        case extraGuidance = "extra_guidance"
        case strictness
        case builtInRules = "built_in_rules"
        case ollama
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dropTopics = try c.decodeIfPresent([String].self, forKey: .dropTopics) ?? []
        extraGuidance = try c.decodeIfPresent(String.self, forKey: .extraGuidance) ?? ""
        strictness = try? c.decodeIfPresent(FilterStrictness.self, forKey: .strictness)
        builtInRules = try c.decodeIfPresent([String].self, forKey: .builtInRules) ?? []
        ollama = try c.decodeIfPresent(OllamaConfig.self, forKey: .ollama)
    }
}

/// Partial update for `PATCH /api/config/filter`.
public struct FilterPatch: Encodable, Sendable {
    public var dropTopics: [String]?
    public var extraGuidance: String?
    public var strictness: FilterStrictness?

    enum CodingKeys: String, CodingKey {
        case dropTopics = "drop_topics"
        case extraGuidance = "extra_guidance"
        case strictness
    }

    public init(dropTopics: [String]? = nil, extraGuidance: String? = nil, strictness: FilterStrictness? = nil) {
        self.dropTopics = dropTopics
        self.extraGuidance = extraGuidance
        self.strictness = strictness
    }
}
