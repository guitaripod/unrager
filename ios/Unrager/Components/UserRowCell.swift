import UIKit
import UnragerKit

/// What a user row shows, so followers, following, likers and notification
/// actor lists can share one cell.
struct UserRow: Hashable {
    let id: String
    let name: String
    let handle: String
    let verified: Bool
    let avatarURL: URL?

    init(_ user: User) {
        id = user.restID
        name = user.name
        handle = user.handle
        verified = user.verified
        avatarURL = user.avatarURL.flatMap(URL.init)
    }

    init(_ actor: NotificationActor) {
        id = actor.restID
        name = actor.name
        handle = actor.handle
        verified = actor.verified
        avatarURL = actor.avatarURL.flatMap(URL.init)
    }
}

/// An avatar, name, handle and verified-badge row. The avatar load is tied to
/// the row it was started for: a recycled cell drops the old load and ignores a
/// late result, so a fast scroll can never leave one user's picture on another.
final class UserRowCell: UICollectionViewListCell {
    private static let avatarSize: CGFloat = 40

    private var boundID: String?
    private var avatarTask: Task<Void, Never>?

    func configure(with row: UserRow) {
        avatarTask?.cancel()
        boundID = row.id

        var content = UIListContentConfiguration.subtitleCell()
        content.attributedText = TwemojiText.attributed(
            row.name, font: DesignSystem.Typography.body(), color: DesignSystem.Color.label)
        content.secondaryText = "@\(row.handle)"
        content.secondaryTextProperties.color = DesignSystem.Color.secondaryLabel
        let size = CGSize(width: Self.avatarSize, height: Self.avatarSize)
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let url = AppSettings.imagesEnabled ? row.avatarURL : nil
        let cached = url.flatMap { ImageLoader.cachedImageImmediately(for: $0, pointSize: size, scale: scale) }
        content.image = cached ?? DesignSystem.icon("person.crop.circle.fill", pointSize: Self.avatarSize)
        content.imageProperties.tintColor = DesignSystem.Color.tertiaryLabel
        content.imageProperties.maximumSize = size
        content.imageProperties.reservedLayoutSize = size
        content.imageProperties.cornerRadius = Self.avatarSize / 2
        contentConfiguration = content
        accessibilityLabel = "\(row.name), @\(row.handle)\(row.verified ? ", verified" : "")"
        accessibilityTraits = .button
        accessories = accessories(verified: row.verified)

        guard cached == nil, let url else { return }
        avatarTask = Task { [weak self] in
            let image = await ImageLoader.image(for: url, pointSize: size, scale: scale)
            guard !Task.isCancelled, let self, let image, self.boundID == row.id,
                  var content = self.contentConfiguration as? UIListContentConfiguration else { return }
            content.image = image
            self.contentConfiguration = content
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarTask?.cancel()
        avatarTask = nil
        boundID = nil
    }

    /// Every row ends in the disclosure chevron; a verified account shows its
    /// badge just before it, so verified and other rows line up.
    private func accessories(verified: Bool) -> [UICellAccessory] {
        guard verified else { return [.disclosureIndicator()] }
        let badge = UIImageView(image: DesignSystem.icon("checkmark.seal.fill", pointSize: 16))
        badge.tintColor = DesignSystem.Color.verified
        return [.customView(configuration: .init(customView: badge, placement: .trailing())),
                .disclosureIndicator()]
    }
}
