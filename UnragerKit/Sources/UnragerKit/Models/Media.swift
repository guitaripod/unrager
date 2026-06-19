import Foundation

public struct TweetURL: Decodable, Sendable, Hashable {
    public let expandedURL: String
    public let displayURL: String

    enum CodingKeys: String, CodingKey {
        case expandedURL = "expanded_url"
        case displayURL = "display_url"
    }
}

public struct PollOption: Decodable, Sendable, Hashable {
    public let label: String
    public let count: Int
}

/// The X media variants. Serialized externally-tagged: unit variants are a
/// bare string in `kind` (`"photo"`), struct variants nest under their
/// snake_case key (`{"you_tube": {…}}`).
public enum MediaKind: Sendable, Hashable {
    case photo
    case video
    case animatedGif
    case youTube(videoID: String)
    case article(articleID: String, title: String, previewText: String)
    case linkCard(title: String, description: String, domain: String, targetURL: String)
    case broadcast(broadcastID: String, title: String, broadcasterName: String, isLive: Bool)
    case poll(options: [PollOption], endsAt: Date?, countsFinal: Bool)
}

extension MediaKind: Decodable {
    private enum Tag: String, CodingKey {
        case youTube = "you_tube"
        case article
        case linkCard = "link_card"
        case broadcast
        case poll
    }

    private enum YouTubeKeys: String, CodingKey { case videoID = "video_id" }
    private enum ArticleKeys: String, CodingKey {
        case articleID = "article_id"
        case title
        case previewText = "preview_text"
    }
    private enum LinkCardKeys: String, CodingKey {
        case title, description, domain
        case targetURL = "target_url"
    }
    private enum BroadcastKeys: String, CodingKey {
        case broadcastID = "broadcast_id"
        case title
        case broadcasterName = "broadcaster_name"
        case isLive = "is_live"
    }
    private enum PollKeys: String, CodingKey {
        case options
        case endsAt = "ends_at"
        case countsFinal = "counts_final"
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let tag = try? single.decode(String.self) {
            switch tag {
            case "photo": self = .photo
            case "video": self = .video
            case "animated_gif": self = .animatedGif
            default: self = .photo
            }
            return
        }

        let container = try decoder.container(keyedBy: Tag.self)
        if let yt = try? container.nestedContainer(keyedBy: YouTubeKeys.self, forKey: .youTube) {
            self = .youTube(videoID: try yt.decode(String.self, forKey: .videoID))
        } else if let article = try? container.nestedContainer(keyedBy: ArticleKeys.self, forKey: .article) {
            self = .article(
                articleID: try article.decode(String.self, forKey: .articleID),
                title: try article.decode(String.self, forKey: .title),
                previewText: try article.decode(String.self, forKey: .previewText))
        } else if let card = try? container.nestedContainer(keyedBy: LinkCardKeys.self, forKey: .linkCard) {
            self = .linkCard(
                title: try card.decode(String.self, forKey: .title),
                description: try card.decode(String.self, forKey: .description),
                domain: try card.decode(String.self, forKey: .domain),
                targetURL: try card.decode(String.self, forKey: .targetURL))
        } else if let bc = try? container.nestedContainer(keyedBy: BroadcastKeys.self, forKey: .broadcast) {
            self = .broadcast(
                broadcastID: try bc.decode(String.self, forKey: .broadcastID),
                title: try bc.decode(String.self, forKey: .title),
                broadcasterName: try bc.decode(String.self, forKey: .broadcasterName),
                isLive: try bc.decode(Bool.self, forKey: .isLive))
        } else if let poll = try? container.nestedContainer(keyedBy: PollKeys.self, forKey: .poll) {
            self = .poll(
                options: try poll.decode([PollOption].self, forKey: .options),
                endsAt: try poll.decodeIfPresent(Date.self, forKey: .endsAt),
                countsFinal: try poll.decode(Bool.self, forKey: .countsFinal))
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: Tag.poll,
                in: container,
                debugDescription: "Unknown MediaKind variant")
        }
    }
}

public struct Media: Decodable, Sendable, Hashable {
    public let kind: MediaKind
    public let url: String
    public let videoURL: String?
    public let altText: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case url
        case videoURL = "video_url"
        case altText = "alt_text"
    }

    public var isVideo: Bool {
        switch kind {
        case .video, .animatedGif: return true
        default: return false
        }
    }
}
