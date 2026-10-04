import UIKit
import UnragerKit

/// What a row can do beyond opening: show a person, list the people behind a
/// group, follow back.
struct NotificationRowActions {
    var openProfile: (String) -> Void
    var openPeople: () -> Void
    var followBack: () -> Void
    var toggleLike: () -> Void
}

/// One notification: the faces and action chip, who did what and when, the post
/// it is about, and, for a new follower, a Follow back button. Unread rows carry
/// a dot in the margin and a faint wash of the accent; a row that has just
/// arrived glows once and fades.
final class NotificationCell: UICollectionViewListCell {
    private static let followSlotWidth: CGFloat = 120
    private static let likeSide: CGFloat = 36

    private let avatars = NotificationAvatarStackView()
    private let unreadDot = UIView()
    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let postView = NotificationPostView()
    private let followSlot = UIView()
    private let followButton = UIButton(type: .system)
    private let likeButton = UIButton(type: .system)
    private let flashView = UIView()
    private let textColumn = UIStackView()
    private var unread = false
    private var applied: (notification: XNotification, follow: FollowStateLoader.State?, liked: Bool?,
                          actions: NotificationRowActions)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: NotificationCell, _) in
            cell.redraw()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        automaticallyUpdatesBackgroundConfiguration = false
        accessibilityIgnoresInvertColors = false

        flashView.backgroundColor = DesignSystem.Color.accent
        flashView.alpha = 0
        flashView.isUserInteractionEnabled = false
        flashView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(flashView)
        flashView.pinEdges(to: contentView)

        unreadDot.backgroundColor = DesignSystem.Color.badge
        unreadDot.layer.cornerRadius = 4
        unreadDot.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(unreadDot)

        titleLabel.numberOfLines = 0
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.font = DesignSystem.Typography.metric()
        timeLabel.textColor = DesignSystem.Color.tertiaryLabel
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [titleLabel, timeLabel])
        header.alignment = .firstBaseline
        header.spacing = DesignSystem.Spacing.s

        subtitleLabel.font = DesignSystem.Typography.metric()
        subtitleLabel.textColor = DesignSystem.Color.secondaryLabel
        subtitleLabel.isHidden = true

        textColumn.axis = .vertical
        textColumn.spacing = 2
        textColumn.addArrangedSubview(header)
        textColumn.addArrangedSubview(subtitleLabel)
        textColumn.addArrangedSubview(postView)
        textColumn.setCustomSpacing(8, after: subtitleLabel)
        textColumn.setCustomSpacing(8, after: header)

        followButton.translatesAutoresizingMaskIntoConstraints = false
        followButton.addAction(UIAction { [weak self] _ in self?.applied?.actions.followBack() }, for: .touchUpInside)
        followSlot.addSubview(followButton)
        NSLayoutConstraint.activate([
            followButton.topAnchor.constraint(equalTo: followSlot.topAnchor),
            followButton.leadingAnchor.constraint(greaterThanOrEqualTo: followSlot.leadingAnchor),
            followButton.trailingAnchor.constraint(equalTo: followSlot.trailingAnchor),
            followButton.bottomAnchor.constraint(lessThanOrEqualTo: followSlot.bottomAnchor),
            followSlot.widthAnchor.constraint(equalToConstant: Self.followSlotWidth),
        ])

        likeButton.addAction(UIAction { [weak self] _ in self?.applied?.actions.toggleLike() }, for: .touchUpInside)
        likeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            likeButton.widthAnchor.constraint(equalToConstant: Self.likeSide),
            likeButton.heightAnchor.constraint(equalToConstant: Self.likeSide),
        ])

        avatars.addAction(UIAction { [weak self] _ in
            Haptics.selection()
            self?.avatarTapped()
        }, for: .touchUpInside)

        avatars.setContentHuggingPriority(.required, for: .horizontal)
        avatars.setContentCompressionResistancePriority(.required, for: .horizontal)
        textColumn.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        followSlot.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            avatars.widthAnchor.constraint(equalToConstant: NotificationAvatarStackView.side),
            avatars.heightAnchor.constraint(equalToConstant: NotificationAvatarStackView.side),
        ])

        let row = UIStackView(arrangedSubviews: [avatars, textColumn, followSlot, likeButton])
        row.alignment = .top
        row.spacing = DesignSystem.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 16)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: margins.topAnchor),
            row.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),
            unreadDot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 7),
            unreadDot.centerYAnchor.constraint(equalTo: avatars.centerYAnchor),
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: textColumn.leadingAnchor),
        ])
    }

    /// The row's wash: a hint of the accent when unread, so the unread block
    /// reads as one band without shouting.
    private static var unreadWash: UIColor {
        UIColor { trait in
            DesignSystem.Color.background.resolvedColor(with: trait)
                .blended(with: DesignSystem.Color.accent.resolvedColor(with: trait), amount: 0.05)
        }
    }

    private var rowColor: UIColor { unread ? Self.unreadWash : DesignSystem.Color.background }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = state.isHighlighted || state.isSelected ? DesignSystem.Color.surface : rowColor
        backgroundConfiguration = background
    }

    func configure(notification: XNotification, unread: Bool, glow: Bool, follow: FollowStateLoader.State?,
                   liked: Bool?, actions: NotificationRowActions) {
        self.unread = unread
        applied = (notification, follow, liked, actions)
        let type = NotificationType(raw: notification.type)
        let style = type.style
        setNeedsUpdateConfiguration()

        unreadDot.isHidden = !unread
        titleLabel.attributedText = NotificationPresentation.title(for: notification)
        timeLabel.text = Format.relativeTime(notification.timestamp)

        avatars.configure(actors: notification.actors, style: style, ring: rowColor)
        avatars.isUserInteractionEnabled = !notification.actors.isEmpty

        configureBody(for: notification, type: type, style: style)
        configureFollow(for: notification, state: follow)
        configureLike(liked)
        configureAccessibility(for: notification, unread: unread)
        if glow { playGlow() }
    }

    private func configureBody(for notification: XNotification, type: NotificationType, style: NotificationStyle) {
        let snippet = notification.targetTweetSnippet
        var showsPost = false
        if type.isConversation || type.isEngagement || type == .communityNote {
            showsPost = postView.configure(
                text: snippet, look: type.isConversation ? .bubble : .quoted, tint: style.color,
                likeCount: type.isEngagement ? notification.targetTweetLikeCount : nil,
                thumbURL: notification.thumbnailURL,
                isVideo: notification.targetMedia.first?.isVideo ?? false)
        }
        postView.isHidden = !showsPost
        if !showsPost { postView.prepareForReuse() }

        let singleFollow = type == .follow && NotificationPresentation.peopleCount(notification) == 1
        if singleFollow, let actor = notification.actors.first {
            subtitleLabel.text = "@\(actor.handle)"
            subtitleLabel.isHidden = false
        } else if !showsPost, let snippet, !snippet.isEmpty {
            subtitleLabel.text = snippet
            subtitleLabel.numberOfLines = 3
            subtitleLabel.isHidden = false
        } else {
            subtitleLabel.isHidden = true
        }
    }

    private func configureFollow(for notification: XNotification, state: FollowStateLoader.State?) {
        let single = NotificationType(raw: notification.type) == .follow
            && NotificationPresentation.peopleCount(notification) == 1
        guard single, let state, state != .unknown else {
            followSlot.isHidden = true
            return
        }
        followSlot.isHidden = false
        var config: UIButton.Configuration
        switch state {
        case .notFollowing:
            config = .filled()
            config.title = "Follow back"
            config.baseBackgroundColor = DesignSystem.Color.accent
            config.baseForegroundColor = .white
        case .following, .followingNow:
            config = .tinted()
            config.title = "Following"
            config.image = DesignSystem.icon("checkmark", pointSize: 11, weight: .bold)
            config.imagePadding = 4
            config.baseBackgroundColor = DesignSystem.Color.secondaryLabel
            config.baseForegroundColor = DesignSystem.Color.secondaryLabel
        case .loading, .unknown:
            config = .tinted()
            config.title = " "
            config.showsActivityIndicator = true
            config.baseBackgroundColor = DesignSystem.Color.secondaryLabel
        }
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = DesignSystem.Typography.system(13, weight: .semibold)
            return outgoing
        }
        followButton.configuration = config
        followButton.isUserInteractionEnabled = state == .notFollowing
    }

    /// A heart for a post the user can like back; hidden for the rest. The
    /// heart fills in the like colour once liked.
    private func configureLike(_ liked: Bool?) {
        guard let liked else {
            likeButton.isHidden = true
            return
        }
        likeButton.isHidden = false
        var config = UIButton.Configuration.plain()
        config.image = DesignSystem.icon(liked ? "heart.fill" : "heart", pointSize: 17)
        config.baseForegroundColor = liked ? DesignSystem.Color.like : DesignSystem.Color.tertiaryLabel
        config.contentInsets = .zero
        likeButton.configuration = config
        likeButton.accessibilityLabel = liked ? "Unlike" : "Like"
        likeButton.accessibilityTraits = liked ? [.button, .selected] : .button
    }

    private func configureAccessibility(for notification: XNotification, unread: Bool) {
        let copy = NotificationPresentation.bannerCopy(for: notification)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(unread ? "Unread. " : "")\(copy.title). \(copy.body). \(Format.relativeTime(notification.timestamp)) ago"
        var custom = notification.actors.prefix(NotificationAvatarStackView.maxFaces).map { actor in
            UIAccessibilityCustomAction(name: "Open \(actor.name)'s profile") { [weak self] _ in
                self?.applied?.actions.openProfile(actor.handle)
                return true
            }
        }
        if NotificationPresentation.hasPeopleList(notification) {
            custom.append(UIAccessibilityCustomAction(name: "See everyone") { [weak self] _ in
                self?.applied?.actions.openPeople()
                return true
            })
        }
        if let liked = applied?.liked {
            custom.append(UIAccessibilityCustomAction(name: liked ? "Unlike" : "Like") { [weak self] _ in
                self?.applied?.actions.toggleLike()
                return true
            })
        }
        if case .notFollowing? = applied?.follow {
            custom.append(UIAccessibilityCustomAction(name: "Follow back") { [weak self] _ in
                self?.applied?.actions.followBack()
                return true
            })
        }
        accessibilityCustomActions = custom
    }

    private func avatarTapped() {
        guard let applied else { return }
        if NotificationPresentation.hasPeopleList(applied.notification) {
            applied.actions.openPeople()
        } else if let actor = applied.notification.actors.first {
            applied.actions.openProfile(actor.handle)
        }
    }

    /// A single soft pulse of the accent over a row that just arrived.
    private func playGlow() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        flashView.layer.removeAllAnimations()
        flashView.alpha = 0.2
        UIView.animate(withDuration: 1.6, delay: 0.3, options: [.curveEaseOut, .allowUserInteraction]) {
            self.flashView.alpha = 0
        }
    }

    private func redraw() {
        guard let applied else { return }
        avatars.prepareForReuse()
        configure(notification: applied.notification, unread: unread, glow: false, follow: applied.follow,
                  liked: applied.liked, actions: applied.actions)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatars.prepareForReuse()
        postView.prepareForReuse()
        flashView.layer.removeAllAnimations()
        flashView.alpha = 0
        applied = nil
        unread = false
    }
}

private extension UIColor {
    /// This colour moved `amount` of the way towards `other`, in sRGB.
    func blended(with other: UIColor, amount: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return self }
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount,
                       blue: b1 + (b2 - b1) * amount, alpha: 1)
    }
}
