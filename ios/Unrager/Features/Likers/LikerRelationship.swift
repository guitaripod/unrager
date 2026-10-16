import UIKit
import UnragerKit

/// Where a person stands with the viewer: who follows whom.
enum Standing: Equatable {
    case mutual
    case followsYou
    case youFollow
    case stranger

    /// nil unless both directions are known: a list from an older server says
    /// only whether the viewer follows, and half a fact is not shown as a whole.
    init?(following: Bool?, followsMe: Bool?) {
        switch (following, followsMe) {
        case (true?, true?): self = .mutual
        case (false?, true?): self = .followsYou
        case (true?, false?): self = .youFollow
        case (false?, false?): self = .stranger
        default: return nil
        }
    }

    /// The colour of the ring, the legend dot and the chip: teal for people
    /// who follow each way, amber for a follower the viewer hasn't followed
    /// back, blue for someone only the viewer follows.
    var tint: UIColor {
        switch self {
        case .mutual: return DesignSystem.Color.follow
        case .followsYou: return DesignSystem.Color.spark
        case .youFollow: return DesignSystem.Color.accent
        case .stranger: return DesignSystem.Color.tertiaryLabel
        }
    }

    /// The short phrase after a handle, for the standings that call for one;
    /// someone only the viewer follows or doesn't know already reads from the
    /// button and the follower count.
    var phrase: String? {
        switch self {
        case .mutual: return "Mutual"
        case .followsYou: return "Follows you"
        case .youFollow, .stranger: return nil
        }
    }

    var drawsRing: Bool { phrase != nil }
}

extension UserRow {
    /// This person's standing with the viewer; nil for the viewer's own row
    /// and where the list doesn't say.
    @MainActor var standing: Standing? {
        isViewer ? nil : Standing(following: following, followsMe: followsMe)
    }

    /// The label on the row's button: a follower the viewer hasn't followed
    /// back is offered "Follow back" rather than a plain "Follow".
    @MainActor var followTitle: String {
        if following == true { return "Following" }
        return standing == .followsYou ? "Follow back" : "Follow"
    }
}

/// How many of the people loaded so far stand each way. The viewer's own like
/// is left out: it is no one's relationship.
struct LikerTally: Equatable {
    private(set) var mutual = 0
    private(set) var followsYou = 0
    private(set) var youFollow = 0
    private(set) var strangers = 0
    private(set) var unplaced = 0
    private(set) var verified = 0

    @MainActor init(_ rows: some Sequence<UserRow>) {
        for row in rows where !row.isViewer {
            if row.verified { verified += 1 }
            switch row.standing {
            case .mutual: mutual += 1
            case .followsYou: followsYou += 1
            case .youFollow: youFollow += 1
            case .stranger: strangers += 1
            case nil: unplaced += 1
            }
        }
    }

    var placed: Int { mutual + followsYou + youFollow + strangers }
    var listed: Int { placed + unplaced }
    var followers: Int { mutual + followsYou }
    var followed: Int { mutual + youFollow }

    /// Whether the list said enough about anyone to draw standings at all.
    var hasStandings: Bool { placed > 0 }

    func count(of standing: Standing) -> Int {
        switch standing {
        case .mutual: return mutual
        case .followsYou: return followsYou
        case .youFollow: return youFollow
        case .stranger: return strangers
        }
    }
}

/// A way to narrow the loaded likers to some of them.
enum LikerLens: String, CaseIterable {
    case everyone
    case followers
    case followBack
    case followed
    case verified

    var title: String {
        switch self {
        case .everyone: return "All"
        case .followers: return "Follow you"
        case .followBack: return "Follow back"
        case .followed: return "You follow"
        case .verified: return "Verified"
        }
    }

    var tint: UIColor {
        self == .followBack ? Standing.followsYou.tint : DesignSystem.Color.accent
    }

    @MainActor func includes(_ row: UserRow) -> Bool {
        switch self {
        case .everyone: return true
        case .verified: return row.verified
        case .followers: return row.standing == .mutual || row.standing == .followsYou
        case .followBack: return row.standing == .followsYou
        case .followed: return row.standing == .mutual || row.standing == .youFollow
        }
    }

    func count(in tally: LikerTally) -> Int {
        switch self {
        case .everyone: return tally.listed
        case .verified: return tally.verified
        case .followers: return tally.followers
        case .followBack: return tally.followsYou
        case .followed: return tally.followed
        }
    }

    /// Said under the list when the lens leaves nobody in it.
    func emptyNote(listed: Int) -> String {
        let among = "among the \(listed.formatted()) people X lists"
        switch self {
        case .everyone: return "Nobody to show."
        case .verified: return "No verified accounts \(among)."
        case .followers: return "Nobody \(among) follows you."
        case .followBack: return "You follow back everyone \(among) who follows you."
        case .followed: return "You follow nobody \(among)."
        }
    }
}

/// What the Liked by header shows about the people the list holds.
struct LikersSummary: Equatable {
    var likeCount: Int?
    var tally: LikerTally
    /// Followers the viewer hasn't followed back, for the faces beside their
    /// legend row.
    var followBackFaces: [UserRow]
    var loading: Bool

    static let maxFaces = 4
    /// How many people make narrowing worth offering.
    static let minimumForLenses = 6

    /// Whether there are enough people loaded to offer chips over them.
    var offersLenses: Bool { tally.listed >= Self.minimumForLenses }

    @MainActor init(likeCount: Int?, rows: [UserRow], loading: Bool) {
        self.likeCount = likeCount
        self.tally = LikerTally(rows)
        self.followBackFaces = Array(rows.lazy.filter { $0.standing == .followsYou }.prefix(Self.maxFaces))
        self.loading = loading
    }

    /// "1,284 likes".
    static func likesTitle(_ count: Int) -> String {
        count == 1 ? "1 like" : "\(count.formatted()) likes"
    }

    /// Whether the first page is still on its way, so the header holds the
    /// places of the figures it will show.
    var isPlaceholder: Bool { loading && tally.listed == 0 }

    /// What the legend is counting, so a partial list isn't taken for all of it.
    var scope: String {
        if loading, tally.listed == 0 { return "Loading the people who liked this…" }
        let listed = tally.listed
        guard listed > 0 else { return "Nobody to show yet." }
        if let likeCount, likeCount > listed {
            return "Among the \(listed.formatted()) of \(likeCount.formatted()) X lists"
        }
        return listed == 1 ? "The person who liked this" : "Everyone who liked this"
    }

    /// The legend as one spoken line.
    var spokenLegend: String {
        guard tally.hasStandings else { return scope }
        return "\(scope). \(tally.mutual) mutual, \(tally.followsYou) follow you and you don't follow back, "
            + "\(tally.youFollow) you follow, \(tally.strangers) neither."
    }
}
