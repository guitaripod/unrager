import AppKit
import UnragerKit

/// A paginated list of the users who liked a tweet. Rows show avatar, name +
/// verified badge, handle, and follower counts; selecting a user opens their
/// profile. Paginates on scroll via the `LikersPage` cursor.
@MainActor
final class LikersViewController: NSViewController {
    weak var navigator: (any FeedNavigator)?

    private let tweetID: String
    private let api = AppEnvironment.shared.api
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyState = EmptyStateView()

    private var users: [User] = []
    private var cursor: String?
    private var loading = false
    private var exhausted = false
    private var seenIDs = Set<String>()

    init(tweetID: String, navigator: (any FeedNavigator)?) {
        self.tweetID = tweetID
        self.navigator = navigator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let background = BackgroundView(color: DesignSystem.Color.background)
        background.onAppearanceChange = { [weak self] in self?.tableView.reloadData() }
        view = background
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Liked by"
        configureTable()
        emptyState.isHidden = true
        emptyState.onRetry = { [weak self] in self?.load(reset: true) }
        view.addManaged(emptyState)
        emptyState.pinEdges(to: view)
        load(reset: true)
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("user"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.usesAutomaticRowHeights = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        view.addManaged(scrollView)
        scrollView.pinEdges(to: view)

        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    private func load(reset: Bool) {
        guard !loading, reset || !exhausted else { return }
        loading = true
        if reset { cursor = nil; exhausted = false }
        emptyState.isHidden = true
        Task {
            defer { loading = false }
            do {
                let page = try await api.likers(tweetID: tweetID, cursor: reset ? nil : cursor)
                if reset { users.removeAll(); seenIDs.removeAll() }
                for user in page.users where !seenIDs.contains(user.restID) {
                    seenIDs.insert(user.restID)
                    users.append(user)
                }
                cursor = page.cursor
                if page.cursor == nil { exhausted = true }
                tableView.reloadData()
                if users.isEmpty {
                    emptyState.show(symbol: "heart", title: "No likes yet")
                }
            } catch {
                if users.isEmpty {
                    emptyState.show(symbol: "exclamationmark.triangle", title: "Couldn't load likes",
                                    subtitle: error.localizedDescription, showRetry: true)
                }
                AppLogger.shared.warn("likers load failed: \(error)", category: .timeline)
            }
        }
    }

    @objc private func scrolled() {
        let visible = tableView.rows(in: scrollView.contentView.documentVisibleRect)
        guard visible.length > 0 else { return }
        let last = visible.location + visible.length - 1
        if last >= users.count - 3 { load(reset: false) }
    }

    @objc private func rowDoubleClicked() {
        open(row: tableView.clickedRow)
    }

    private func open(row: Int) {
        guard row >= 0, row < users.count else { return }
        navigator?.openProfile(handle: users[row].handle)
    }
}

extension LikersViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { users.count }
}

extension LikersViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = UserRowView.reuseID
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? UserRowView
            ?? UserRowView(identifier: id)
        cell.configure(with: users[row], imagesEnabled: AppSettings.imagesEnabled)
        return cell
    }
}

/// A compact user row: avatar, name + verified, handle, follower counts.
final class UserRowView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("UserRowView")

    private let avatar = AsyncImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let verifiedBadge = NSImageView()
    private let handleLabel = NSTextField(labelWithString: "")
    private let countsLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        avatar.setRounded(20)
        avatar.setFill()

        nameLabel.font = DesignSystem.Typography.name()
        nameLabel.textColor = DesignSystem.Color.label
        nameLabel.lineBreakMode = .byTruncatingTail
        verifiedBadge.image = DesignSystem.icon("checkmark.seal.fill", pointSize: 12)
        verifiedBadge.contentTintColor = DesignSystem.Color.verified
        verifiedBadge.setContentHuggingPriority(.required, for: .horizontal)
        handleLabel.font = DesignSystem.Typography.handle()
        handleLabel.textColor = DesignSystem.Color.secondaryLabel
        countsLabel.font = DesignSystem.Typography.metric()
        countsLabel.textColor = DesignSystem.Color.secondaryLabel

        let nameRow = NSStackView(views: [nameLabel, verifiedBadge, NSView()])
        nameRow.orientation = .horizontal
        nameRow.spacing = DesignSystem.Spacing.xs
        nameRow.alignment = .firstBaseline

        let textColumn = NSStackView(views: [nameRow, handleLabel, countsLabel])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = DesignSystem.Spacing.xxs

        separator.boxType = .separator

        addManaged(avatar)
        addManaged(textColumn)
        addManaged(separator)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 40),
            avatar.heightAnchor.constraint(equalToConstant: 40),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignSystem.Spacing.l),
            avatar.topAnchor.constraint(equalTo: topAnchor, constant: DesignSystem.Spacing.m),
            avatar.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -DesignSystem.Spacing.m),
            textColumn.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: DesignSystem.Spacing.m),
            textColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignSystem.Spacing.l),
            textColumn.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            nameRow.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    func configure(with user: User, imagesEnabled: Bool) {
        nameLabel.stringValue = user.name
        verifiedBadge.isHidden = !user.verified
        handleLabel.stringValue = "@\(user.handle)"
        countsLabel.stringValue = "\(Format.count(user.followers)) Followers"
        setAccessibilityLabel("\(user.name), @\(user.handle)")
        if imagesEnabled, let url = user.avatarURL.flatMap(URL.init) {
            avatar.load(url: url, targetSize: CGSize(width: 40, height: 40))
        } else {
            avatar.cancel()
            avatar.image = DesignSystem.icon("person.crop.circle.fill", pointSize: 32)
            avatar.contentTintColor = DesignSystem.Color.tertiaryLabel
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatar.cancel()
    }
}
