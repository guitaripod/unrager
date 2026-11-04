import UIKit
import UnragerKit

/// What a user row shows, so followers, following, likers and notification
/// actor lists can share one cell. `following` is nil where the list can't say
/// whether the viewer follows the person, and the row then offers no button.
struct UserRow: Hashable {
    let id: String
    let name: String
    let handle: String
    let verified: Bool
    let avatarURL: URL?
    let bio: String?
    let followers: Int?
    /// Whether the viewer follows the person; nil where the list can't say.
    var following: Bool?
    /// Whether the person follows the viewer; nil where the list can't say.
    let followsMe: Bool?

    init(_ user: User) {
        id = user.restID
        name = user.name
        handle = user.handle
        verified = user.verified
        avatarURL = user.avatarURL.flatMap(URL.init)
        bio = user.bio.flatMap { $0.isEmpty ? nil : $0 }
        followers = user.followers
        following = user.followedByMe
        followsMe = user.followsMe
    }

    init(_ actor: NotificationActor) {
        id = actor.restID
        name = actor.name
        handle = actor.handle
        verified = actor.verified
        avatarURL = actor.avatarURL.flatMap(URL.init)
        bio = nil
        followers = nil
        following = nil
        followsMe = nil
    }

    /// Whether this row is the signed-in account, which has no one to follow.
    @MainActor var isViewer: Bool {
        guard let viewer = AppEnvironment.shared.currentHandle else { return false }
        return viewer.caseInsensitiveCompare(handle) == .orderedSame
    }
}

/// A person: a round avatar, the name with its verified seal, the handle, up to
/// two lines of bio and, where the list knows, a Follow / Following button. A
/// detailed row (the people who liked a post) also says where the person stands
/// with the viewer: a follower is ringed in amber (not followed back) or teal
/// (mutual) and named so after the handle, with their follower count after it
/// for everyone else. The avatar load is tied to the row it was started for: a
/// recycled cell drops the old load and ignores a late result, so a fast scroll
/// can never leave one user's picture on another.
final class UserRowCell: UICollectionViewListCell {
    static let avatarSize: CGFloat = 48
    private static let ringWidth: CGFloat = 2.5
    private static let ringGap: CGFloat = 4

    var onToggleFollow: (() -> Void)?

    private let avatar = UIImageView()
    private let nameLabel = UILabel()
    private let flagLabel = UILabel()
    private let seal = UIImageView(image: DesignSystem.icon("checkmark.seal.fill", pointSize: 14))
    private let handleLabel = UILabel()
    private let phraseLabel = UILabel()
    private let bioLabel = UILabel()
    private let metaRow = UIStackView()
    private let metaSpacer = UIView()
    private let ring = AvatarRingView(lineWidth: UserRowCell.ringWidth)
    private let followButton = UIButton(type: .system)
    /// The Follow button beside the name, or, at the accessibility text
    /// sizes, under the text where the name keeps the row's whole width.
    private var besideText: [NSLayoutConstraint] = []
    private var underText: [NSLayoutConstraint] = []
    private var textToEdge: NSLayoutConstraint!
    private var textBottom: NSLayoutConstraint!
    private var boundID: String?
    private var avatarTask: Task<Void, Never>?
    private var following: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        avatar.contentMode = .scaleAspectFill
        avatar.clipsToBounds = true
        avatar.layer.cornerRadius = Self.avatarSize / 2
        avatar.layer.cornerCurve = .continuous
        avatar.tintColor = DesignSystem.Color.tertiaryLabel
        avatar.backgroundColor = .secondarySystemFill
        avatar.accessibilityIgnoresInvertColors = true

        nameLabel.textColor = DesignSystem.Color.label
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        flagLabel.setContentHuggingPriority(.required, for: .horizontal)
        flagLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        flagLabel.isHidden = true
        flagLabel.isAccessibilityElement = false
        seal.tintColor = DesignSystem.Color.verified
        seal.setContentHuggingPriority(.required, for: .horizontal)
        seal.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        let nameRow = UIStackView(arrangedSubviews: [nameLabel, flagLabel, seal, spacer])
        nameRow.spacing = DesignSystem.Spacing.xs
        nameRow.alignment = .center

        handleLabel.textColor = DesignSystem.Color.secondaryLabel
        handleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        phraseLabel.setContentHuggingPriority(.required, for: .horizontal)
        phraseLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        phraseLabel.isHidden = true
        metaSpacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        [handleLabel, phraseLabel, metaSpacer].forEach(metaRow.addArrangedSubview)
        bioLabel.textColor = DesignSystem.Color.label
        bioLabel.numberOfLines = 2

        let texts = UIStackView(arrangedSubviews: [nameRow, metaRow, bioLabel])
        texts.axis = .vertical
        texts.spacing = 1
        texts.setCustomSpacing(DesignSystem.Spacing.xs, after: metaRow)
        let tail = UIView()
        tail.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)
        texts.addArrangedSubview(tail)
        texts.setCustomSpacing(0, after: bioLabel)

        applyFonts()

        followButton.setContentHuggingPriority(.required, for: .horizontal)
        followButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        followButton.addAction(UIAction { [weak self] _ in self?.onToggleFollow?() }, for: .touchUpInside)

        for view in [avatar, texts, followButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        contentView.addSubview(ring)
        textToEdge = texts.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -DesignSystem.Spacing.l)
        textBottom = texts.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -DesignSystem.Spacing.m)
        textBottom.priority = .defaultHigh
        let buttonBottom = followButton.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor, constant: -DesignSystem.Spacing.m)
        buttonBottom.priority = .defaultHigh
        besideText = [
            texts.trailingAnchor.constraint(equalTo: followButton.leadingAnchor, constant: -DesignSystem.Spacing.m),
            followButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -DesignSystem.Spacing.l),
            followButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: DesignSystem.Spacing.m),
            textBottom,
        ]
        underText = [
            textToEdge,
            followButton.leadingAnchor.constraint(equalTo: texts.leadingAnchor),
            followButton.topAnchor.constraint(equalTo: texts.bottomAnchor, constant: DesignSystem.Spacing.s),
            buttonBottom,
        ]
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: DesignSystem.Spacing.l),
            avatar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: DesignSystem.Spacing.m),
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -DesignSystem.Spacing.m),
            texts.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: DesignSystem.Spacing.m),
            texts.topAnchor.constraint(equalTo: contentView.topAnchor, constant: DesignSystem.Spacing.m + 1),
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: texts.leadingAnchor),
        ] + ring.surrounding(avatar, gap: Self.ringGap))
        arrangeFollowButton(shown: false)
    }

    /// Sets every text's font for the current text size, the system's and the
    /// app's own, so a row bound after either changed reads at the new size.
    private func applyFonts() {
        nameLabel.font = DesignSystem.Typography.rowName()
        flagLabel.font = DesignSystem.Typography.rowName()
        handleLabel.font = DesignSystem.Typography.metric()
        phraseLabel.font = DesignSystem.Typography.metric()
        bioLabel.font = DesignSystem.Typography.metric()
    }

    func configure(with row: UserRow, detailed: Bool = false) {
        avatarTask?.cancel()
        boundID = row.id
        applyFonts()

        nameLabel.attributedText = TwemojiText.attributed(
            row.name, font: nameLabel.font, color: DesignSystem.Color.label)
        seal.isHidden = !row.verified
        handleLabel.text = "@\(row.handle)"
        bioLabel.attributedText = row.bio.map {
            TwemojiText.attributed($0, font: DesignSystem.Typography.metric(), color: DesignSystem.Color.label)
        }
        bioLabel.isHidden = row.bio == nil
        let standing = detailed ? row.standing : nil
        showFollow(row.isViewer ? nil : row.following, title: row.followTitle)
        showStanding(standing, row: row, detailed: detailed)
        loadAvatar(row)
        applyFlag(for: row)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(row.name), @\(row.handle)\(row.verified ? ", verified" : "")"
            + (standing?.phrase.map { ", \($0.lowercased())" } ?? "")
            + (row.bio.map { ". \($0)" } ?? "")
        accessibilityCustomActions = following.map { current in
            [UIAccessibilityCustomAction(name: current ? "Unfollow" : row.followTitle) { [weak self] _ in
                self?.onToggleFollow?()
                return true
            }]
        }
    }

    /// The phrase after the handle and the ring around the avatar: who follows
    /// the viewer, or else how big the account is.
    private func showStanding(_ standing: Standing?, row: UserRow, detailed: Bool) {
        let phrase: NSAttributedString?
        let lead = isStacked ? "" : " · "
        if let standing, let text = standing.phrase {
            phrase = NSAttributedString(string: "\(lead)\(text)", attributes: [
                .font: DesignSystem.Typography.metricEmphasis(), .foregroundColor: standing.tint,
            ])
        } else if detailed, let followers = row.followers {
            phrase = NSAttributedString(string: "\(lead)\(Format.count(followers)) followers", attributes: [
                .font: DesignSystem.Typography.metric(), .foregroundColor: DesignSystem.Color.tertiaryLabel,
            ])
        } else {
            phrase = nil
        }
        phraseLabel.attributedText = phrase
        phraseLabel.isHidden = phrase == nil
        ring.tint = standing?.drawsRing == true ? standing?.tint : nil
    }

    /// Puts the person's country flag after the name: at once when it resolved
    /// already this session, otherwise when the lookup lands, if the row still
    /// shows that person.
    private func applyFlag(for row: UserRow) {
        let flags = AppEnvironment.shared.flags
        setFlag(flags.cached(restID: row.id)?.flag)
        guard flags.cached(restID: row.id) == nil else { return }
        flags.resolve(restID: row.id, screenName: row.handle) { [weak self] resolved in
            guard let self, self.boundID == row.id else { return }
            self.setFlag(resolved.flag)
            guard resolved.flag != nil, !UIAccessibility.isReduceMotionEnabled else { return }
            self.flagLabel.alpha = 0
            UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction]) { self.flagLabel.alpha = 1 }
        }
    }

    /// Runs `change` on `view` with a quick dissolve, or at once under Reduce
    /// Motion.
    private func dissolve(_ view: UIView, duration: TimeInterval, _ change: @escaping () -> Void) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            change()
            return
        }
        UIView.transition(with: view, duration: duration, options: [.transitionCrossDissolve, .allowUserInteraction],
                          animations: change)
    }

    private func setFlag(_ flag: String?) {
        let text = flag ?? ""
        flagLabel.attributedText = text.isEmpty ? nil : TwemojiText.attributed(
            text, font: flagLabel.font, color: DesignSystem.Color.label)
        flagLabel.isHidden = text.isEmpty
    }

    private func loadAvatar(_ row: UserRow) {
        let size = CGSize(width: Self.avatarSize, height: Self.avatarSize)
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let url = AppSettings.imagesEnabled ? row.avatarURL : nil
        let cached = url.flatMap { ImageLoader.cachedImageImmediately(for: $0, pointSize: size, scale: scale) }
        avatar.contentMode = cached == nil ? .center : .scaleAspectFill
        avatar.image = cached ?? DesignSystem.icon("person.fill", pointSize: 22)
        guard cached == nil, let url else { return }
        avatarTask = Task { [weak self] in
            let image = await ImageLoader.image(for: url, pointSize: size, scale: scale)
            guard !Task.isCancelled, let self, let image, self.boundID == row.id else { return }
            self.avatar.contentMode = .scaleAspectFill
            self.dissolve(self.avatar, duration: 0.2) { self.avatar.image = image }
        }
    }

    /// Shows Follow or Following, or no button when the list can't tell.
    private func showFollow(_ state: Bool?, title: String) {
        following = state
        followButton.isHidden = state == nil
        arrangeFollowButton(shown: state != nil)
        guard let state else { return }
        var config = state ? UIButton.Configuration.gray() : UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.title = title
        config.baseForegroundColor = state ? DesignSystem.Color.label : .white
        config.baseBackgroundColor = state ? nil : DesignSystem.Color.accent
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = DesignSystem.Typography.rowButton()
            return outgoing
        }
        followButton.configuration = config
    }

    /// Whether the row is laid out for an accessibility text size: the name
    /// may take two lines, the follower phrase goes under the handle and the
    /// Follow button under the text, so nothing has to be cut short.
    private var isStacked: Bool { traitCollection.preferredContentSizeCategory.isAccessibilityCategory }

    private func arrangeFollowButton(shown: Bool) {
        let stacked = isStacked
        nameLabel.numberOfLines = stacked ? 2 : 1
        metaRow.axis = stacked ? .vertical : .horizontal
        metaRow.alignment = stacked ? .leading : .firstBaseline
        metaSpacer.isHidden = stacked
        NSLayoutConstraint.deactivate(besideText + underText + [textToEdge, textBottom])
        switch (shown, stacked) {
        case (true, false): NSLayoutConstraint.activate(besideText)
        case (true, true): NSLayoutConstraint.activate(underText)
        case (false, _): NSLayoutConstraint.activate([textToEdge, textBottom])
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarTask?.cancel()
        avatarTask = nil
        boundID = nil
        onToggleFollow = nil
        flagLabel.isHidden = true
        flagLabel.alpha = 1
        ring.tint = nil
    }
}
