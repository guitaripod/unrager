import Foundation

/// X's own analytics for one of the signed-in account's posts, from
/// `GET /api/tweets/{id}/analytics`: the numbers its "Post engagements" view
/// shows. Only the account's own posts have any.
public struct PostAnalytics: Codable, Sendable, Hashable {
    public let impressions: Int
    public let engagements: Int
    public let detailExpands: Int
    public let profileVisits: Int
    public let linkClicks: Int
    public let follows: Int
    public let videoViews: Int?
    /// Impressions in each of the first 48 hours after the post went out.
    public let hourlyImpressions: [Int]

    enum CodingKeys: String, CodingKey {
        case impressions, engagements, follows
        case detailExpands = "detail_expands"
        case profileVisits = "profile_visits"
        case linkClicks = "link_clicks"
        case videoViews = "video_views"
        case hourlyImpressions = "hourly_impressions"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        impressions = try c.decode(Int.self, forKey: .impressions)
        engagements = try c.decode(Int.self, forKey: .engagements)
        detailExpands = try c.decodeIfPresent(Int.self, forKey: .detailExpands) ?? 0
        profileVisits = try c.decodeIfPresent(Int.self, forKey: .profileVisits) ?? 0
        linkClicks = try c.decodeIfPresent(Int.self, forKey: .linkClicks) ?? 0
        follows = try c.decodeIfPresent(Int.self, forKey: .follows) ?? 0
        videoViews = try c.decodeIfPresent(Int.self, forKey: .videoViews)
        hourlyImpressions = try c.decodeIfPresent([Int].self, forKey: .hourlyImpressions) ?? []
    }

    public init(impressions: Int, engagements: Int, detailExpands: Int = 0, profileVisits: Int = 0,
                linkClicks: Int = 0, follows: Int = 0, videoViews: Int? = nil, hourlyImpressions: [Int] = []) {
        self.impressions = impressions
        self.engagements = engagements
        self.detailExpands = detailExpands
        self.profileVisits = profileVisits
        self.linkClicks = linkClicks
        self.follows = follows
        self.videoViews = videoViews
        self.hourlyImpressions = hourlyImpressions
    }

    /// Engagements as a share of impressions (0 to 1), or nil with no impressions.
    public var engagementRate: Double? {
        impressions > 0 ? Double(engagements) / Double(impressions) : nil
    }
}
