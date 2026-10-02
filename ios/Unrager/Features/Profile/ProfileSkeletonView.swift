import UIKit

/// A whole profile before anything about it is known: a banner, an avatar, bars
/// where the name, bio and counts go, and placeholder posts under them. It is
/// shown only when not even the account's handle is known yet (the very first
/// time the Profile tab opens); after that the tab opens on the saved header.
final class ProfileSkeletonView: SkeletonView {
    private static let bannerHeight: CGFloat = 190
    private static let avatarSide: CGFloat = 76

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityLabel = "Loading profile"
        let banner = shape(radius: 0)
        let avatar = shape(radius: Self.avatarSide / 2)
        let details = BarsSkeletonView(bars: [(0.46, 24), (0.28, 14), (0.9, 14), (0.7, 14), (0.4, 14)], spacing: 10)
        let posts = FeedSkeletonView()
        for view in [banner, avatar, details, posts] { content.addSubview(view) }
        details.translatesAutoresizingMaskIntoConstraints = false
        posts.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: content.topAnchor),
            banner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            banner.heightAnchor.constraint(equalToConstant: Self.bannerHeight),
            avatar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            avatar.centerYAnchor.constraint(equalTo: banner.bottomAnchor),
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSide),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSide),
            details.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 18),
            details.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            details.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            posts.topAnchor.constraint(equalTo: details.bottomAnchor, constant: 28),
            posts.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            posts.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
