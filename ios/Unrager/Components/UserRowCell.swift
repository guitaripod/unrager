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
    var following: Bool?

    init(_ user: User) {
        id = user.restID
        name = user.name
        handle = user.handle
        verified = user.verified
        avatarURL = user.avatarURL.flatMap(URL.init)
        bio = user.bio.flatMap { $0.isEmpty ? nil : $0 }
        following = user.followedByMe
    }

    init(_ actor: NotificationActor) {
        id = actor.restID
        name = actor.name
        handle = actor.handle
        verified = actor.verified
        avatarURL = actor.avatarURL.flatMap(URL.init)
        bio = nil
        following = nil
    }

    /// Whether this row is the signed-in account, which has no one to follow.
    @MainActor var isViewer: Bool {
        guard let viewer = AppEnvironment.shared.currentHandle else { return false }
        return viewer.caseInsensitiveCompare(handle) == .orderedSame
    }
}

/// A person: a round avatar, the name with its verified seal, the handle, up to
/// two lines of bio and, where the list knows, a Follow / Following button. The
/// avatar load is tied to the row it was started for: a recycled cell drops the
/// old load and ignores a late result, so a fast scroll can never leave one
/// user's picture on another.
final class UserRowCell: UICollectionViewListCell {
    static let avatarSize: CGFloat = 48

    var onToggleFollow: (() -> Void)?

    private let avatar = UIImageView()
    private let nameLabel = UILabel()
    private let seal = UIImageView(image: DesignSystem.icon("checkmark.seal.fill", pointSize: 14))
    private let handleLabel = UILabel()
    private let bioLabel = UILabel()
    private let followButton = UIButton(type: .system)
    private var textToButton: NSLayoutConstraint!
    private var textToEdge: NSLayoutConstraint!
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

        nameLabel.font = DesignSystem.Typography.system(16, weight: .semibold)
        nameLabel.textColor = DesignSystem.Color.label
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        seal.tintColor = DesignSystem.Color.verified
        seal.setContentHuggingPriority(.required, for: .horizontal)
        seal.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        let nameRow = UIStackView(arrangedSubviews: [nameLabel, seal, spacer])
        nameRow.spacing = DesignSystem.Spacing.xs
        nameRow.alignment = .center

        handleLabel.font = DesignSystem.Typography.metric()
        handleLabel.textColor = DesignSystem.Color.secondaryLabel
        bioLabel.font = DesignSystem.Typography.metric()
        bioLabel.textColor = DesignSystem.Color.label
        bioLabel.numberOfLines = 2

        let texts = UIStackView(arrangedSubviews: [nameRow, handleLabel, bioLabel])
        texts.axis = .vertical
        texts.spacing = 1
        texts.setCustomSpacing(DesignSystem.Spacing.xs, after: handleLabel)

        followButton.setContentHuggingPriority(.required, for: .horizontal)
        followButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        followButton.addAction(UIAction { [weak self] _ in self?.onToggleFollow?() }, for: .touchUpInside)

        for view in [avatar, texts, followButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        textToButton = texts.trailingAnchor.constraint(equalTo: followButton.leadingAnchor, constant: -DesignSystem.Spacing.m)
        textToEdge = texts.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -DesignSystem.Spacing.l)
        let textBottom = texts.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -DesignSystem.Spacing.m)
        textBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: DesignSystem.Spacing.l),
            avatar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: DesignSystem.Spacing.m),
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -DesignSystem.Spacing.m),
            texts.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: DesignSystem.Spacing.m),
            texts.topAnchor.constraint(equalTo: contentView.topAnchor, constant: DesignSystem.Spacing.m + 1),
            textBottom,
            followButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -DesignSystem.Spacing.l),
            followButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: DesignSystem.Spacing.m),
            textToEdge,
            separatorLayoutGuide.leadingAnchor.constraint(equalTo: texts.leadingAnchor),
        ])
    }

    func configure(with row: UserRow) {
        avatarTask?.cancel()
        boundID = row.id

        nameLabel.attributedText = TwemojiText.attributed(
            row.name, font: nameLabel.font, color: DesignSystem.Color.label)
        seal.isHidden = !row.verified
        handleLabel.text = "@\(row.handle)"
        bioLabel.attributedText = row.bio.map {
            TwemojiText.attributed($0, font: DesignSystem.Typography.metric(), color: DesignSystem.Color.label)
        }
        bioLabel.isHidden = row.bio == nil
        showFollow(row.isViewer ? nil : row.following)
        loadAvatar(row)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(row.name), @\(row.handle)\(row.verified ? ", verified" : "")"
            + (row.bio.map { ". \($0)" } ?? "")
        accessibilityCustomActions = following.map { current in
            [UIAccessibilityCustomAction(name: current ? "Unfollow" : "Follow") { [weak self] _ in
                self?.onToggleFollow?()
                return true
            }]
        }
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
            self.avatar.image = image
        }
    }

    /// Shows Follow or Following, or no button when the list can't tell.
    private func showFollow(_ state: Bool?) {
        following = state
        followButton.isHidden = state == nil
        textToButton.isActive = state != nil
        textToEdge.isActive = state == nil
        guard let state else { return }
        var config = state ? UIButton.Configuration.gray() : UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.title = state ? "Following" : "Follow"
        config.baseForegroundColor = state ? DesignSystem.Color.label : .white
        config.baseBackgroundColor = state ? nil : DesignSystem.Color.accent
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = DesignSystem.Typography.system(14, weight: .semibold)
            return outgoing
        }
        followButton.configuration = config
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarTask?.cancel()
        avatarTask = nil
        boundID = nil
        onToggleFollow = nil
    }
}
