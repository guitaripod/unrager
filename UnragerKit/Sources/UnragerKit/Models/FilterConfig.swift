import Foundation

public struct OllamaConfig: Decodable, Sendable, Hashable {
    public let model: String
    public let host: String
}

/// The rage-filter rubric from `GET /api/config/filter`.
public struct FilterConfig: Decodable, Sendable {
    public let dropTopics: [String]
    public let extraGuidance: String
    public let ollama: OllamaConfig?

    enum CodingKeys: String, CodingKey {
        case dropTopics = "drop_topics"
        case extraGuidance = "extra_guidance"
        case ollama
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dropTopics = try c.decodeIfPresent([String].self, forKey: .dropTopics) ?? []
        extraGuidance = try c.decodeIfPresent(String.self, forKey: .extraGuidance) ?? ""
        ollama = try c.decodeIfPresent(OllamaConfig.self, forKey: .ollama)
    }
}

/// Partial update for `PATCH /api/config/filter`.
public struct FilterPatch: Encodable, Sendable {
    public var dropTopics: [String]?
    public var extraGuidance: String?

    enum CodingKeys: String, CodingKey {
        case dropTopics = "drop_topics"
        case extraGuidance = "extra_guidance"
    }

    public init(dropTopics: [String]? = nil, extraGuidance: String? = nil) {
        self.dropTopics = dropTopics
        self.extraGuidance = extraGuidance
    }
}
