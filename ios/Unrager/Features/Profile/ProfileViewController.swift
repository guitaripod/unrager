import UIKit
import UnragerKit

/// A user's profile: a scrolling header (avatar, name, handle, follower counts,
/// "Brief" LLM summary) above the user's timeline. Subclasses `FeedViewController`
/// so the timeline reuses all the feed machinery; the header rides along as a
/// boundary supplementary item.
final class ProfileViewController: FeedViewController {
    private let handle: String
    private let profileHeader = ProfileHeaderView()

    init(handle: String) {
        self.handle = handle
        super.init(viewModel: TimelineViewModel(source: .user(handle: handle)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        headerView = profileHeader
        super.viewDidLoad()
        title = "@\(handle)"
        profileHeader.onBrief = { [weak self] in
            guard let self else { return }
            let api = AppEnvironment.shared.api
            let handle = self.handle
            self.presentStream(title: "Brief · @\(handle)") { api.briefStream(handle: handle) }
        }
        loadProfile()
    }

    private func loadProfile() {
        Task {
            do {
                let profile = try await AppEnvironment.shared.api.profile(handle: handle)
                profileHeader.configure(with: profile.user)
                title = profile.user.name
                loadFlag(for: profile.user)
            } catch {
                AppLogger.shared.warn("profile load failed: \(error)", category: .profile)
            }
        }
    }

    /// Resolves the profiled user's country flag and shows the header's
    /// "based in <country>" line, mirroring the TUI's profile header. The
    /// header rides as a self-sizing boundary item, so its layout is
    /// invalidated for the extra line to be measured.
    private func loadFlag(for user: User) {
        AppEnvironment.shared.flags.resolve(restID: user.restID, screenName: user.handle) {
            [weak self] resolved in
            guard let self, resolved.country != nil else { return }
            self.profileHeader.setBasedIn(flag: resolved.flag, country: resolved.country)
            self.collectionView.collectionViewLayout.invalidateLayout()
        }
    }
}

private final class ProfileHeaderView: UIView {
    private let avatar = AsyncImageView(frame: .zero)
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let countsLabel = UILabel()
    private let basedInLabel = UILabel()
    private let briefButton = UIButton(configuration: .tinted())
    private let separator = UIView()
    var onBrief: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = DesignSystem.Color.background
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.setRounded(32)

        nameLabel.font = DesignSystem.Typography.title()
        nameLabel.textColor = DesignSystem.Color.label
        nameLabel.numberOfLines = 1
        handleLabel.font = DesignSystem.Typography.handle()
        handleLabel.textColor = DesignSystem.Color.secondaryLabel
        countsLabel.font = DesignSystem.Typography.metric()
        countsLabel.textColor = DesignSystem.Color.secondaryLabel
        basedInLabel.font = DesignSystem.Typography.metric()
        basedInLabel.textColor = DesignSystem.Color.secondaryLabel
        basedInLabel.isHidden = true

        var config = UIButton.Configuration.tinted()
        config.title = "Brief"
        config.image = DesignSystem.icon("sparkles", pointSize: 14)
        config.imagePadding = 6
        config.cornerStyle = .capsule
        briefButton.configuration = config
        briefButton.addAction(UIAction { [weak self] _ in self?.onBrief?() }, for: .touchUpInside)

        let text = UIStackView(arrangedSubviews: [nameLabel, handleLabel, countsLabel, basedInLabel])
        text.axis = .vertical
        text.spacing = 2

        let topRow = UIStackView(arrangedSubviews: [avatar, text])
        topRow.axis = .horizontal
        topRow.spacing = DesignSystem.Spacing.m
        topRow.alignment = .center

        let column = UIStackView(arrangedSubviews: [topRow, briefButton])
        column.axis = .vertical
        column.spacing = DesignSystem.Spacing.m
        column.alignment = .leading

        addManaged(column)
        separator.backgroundColor = DesignSystem.Color.separator
        addManaged(separator)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            avatar.widthAnchor.constraint(equalToConstant: 64),
            avatar.heightAnchor.constraint(equalToConstant: 64),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / max(1, UITraitCollection.current.displayScale)),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with user: User) {
        nameLabel.text = user.name
        handleLabel.text = "@\(user.handle)"
        countsLabel.text = "\(Format.count(user.following)) following · \(Format.count(user.followers)) followers"
        if AppSettings.imagesEnabled, let url = user.avatarURL.flatMap(URL.init) {
            avatar.load(url: url, targetSize: CGSize(width: 64, height: 64))
        }
    }

    /// Shows "based in <flag> <country>" (the TUI's profile line) once the
    /// about-account lookup resolves; hidden when X carries no country.
    func setBasedIn(flag: String?, country: String?) {
        guard let country, !country.isEmpty else {
            basedInLabel.isHidden = true
            return
        }
        let flagPrefix = flag.map { "\($0) " } ?? ""
        basedInLabel.text = "based in \(flagPrefix)\(country)"
        basedInLabel.isHidden = false
    }
}
