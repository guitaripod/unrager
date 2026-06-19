import AppKit
import UnragerKit

/// A list of `XNotification`s. Each row shows an icon for the type, the actor
/// names + action, and the target tweet snippet. Selecting a row opens its
/// target tweet's thread.
@MainActor
final class NotificationsViewController: NSViewController {
    weak var navigator: (any FeedNavigator)?

    private let api = AppEnvironment.shared.api
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyState = EmptyStateView()
    private var items: [XNotification] = []
    private var cursor: String?
    private var loading = false
    private var exhausted = false
    private var seenIDs = Set<String>()

    init(navigator: (any FeedNavigator)?) {
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
        title = "Notifications"
        configureTable()
        emptyState.isHidden = true
        emptyState.onRetry = { [weak self] in self?.load() }
        view.addManaged(emptyState)
        emptyState.pinEdges(to: view)
        load()
    }


    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("notif"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.style = .inset
        tableView.usesAutomaticRowHeights = true
        tableView.selectionHighlightStyle = .regular
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

    func load() { load(reset: true) }

    private func load(reset: Bool) {
        guard !loading, reset || !exhausted else { return }
        loading = true
        if reset { cursor = nil; exhausted = false }
        emptyState.isHidden = true
        Task {
            defer { loading = false }
            do {
                let page = try await api.notifications(cursor: reset ? nil : cursor)
                if reset { items.removeAll(); seenIDs.removeAll() }
                for notif in page.notifications where !seenIDs.contains(notif.id) {
                    seenIDs.insert(notif.id)
                    items.append(notif)
                }
                cursor = page.cursor
                if page.cursor == nil { exhausted = true }
                tableView.reloadData()
                if items.isEmpty {
                    emptyState.show(symbol: "bell", title: "No notifications")
                }
                AppLogger.shared.info("notifications loaded: \(items.count)", category: .timeline)
            } catch {
                if items.isEmpty {
                    emptyState.show(symbol: "exclamationmark.triangle", title: "Couldn't load notifications",
                                    subtitle: error.localizedDescription, showRetry: true)
                }
            }
        }
    }

    func refresh() { load(reset: true) }

    @objc private func scrolled() {
        let visible = tableView.rows(in: scrollView.contentView.documentVisibleRect)
        guard visible.length > 0 else { return }
        let last = visible.location + visible.length - 1
        if last >= items.count - 3 { load(reset: false) }
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        open(items[row])
    }

    private func open(_ notification: XNotification) {
        if let id = notification.targetTweetID {
            navigator?.openThread(id: id)
        } else if let actor = notification.actors.first {
            navigator?.openProfile(handle: actor.handle)
        }
    }

    struct NotifStyle { let color: NSColor; let symbol: String; let verb: String }

    /// Maps a notification's raw type to a colored chip + an action verb. The
    /// type is normalized case-insensitively with underscores stripped so
    /// `community_note`, `CommunityNote`, etc. all land on the same case — the
    /// same rubric as iOS.
    static func style(for rawType: String) -> NotifStyle {
        switch rawType.lowercased().replacingOccurrences(of: "_", with: "") {
        case "like", "favorite": return .init(color: DesignSystem.Color.like, symbol: "heart.fill", verb: "liked your post")
        case "retweet", "repost": return .init(color: DesignSystem.Color.retweet, symbol: "arrow.2.squarepath", verb: "reposted you")
        case "reply": return .init(color: DesignSystem.Color.accent, symbol: "arrowshape.turn.up.left.fill", verb: "replied")
        case "mention": return .init(color: DesignSystem.Color.quote, symbol: "at", verb: "mentioned you")
        case "follow": return .init(color: DesignSystem.Color.retweet, symbol: "person.fill.badge.plus", verb: "followed you")
        case "quote": return .init(color: DesignSystem.Color.quote, symbol: "quote.bubble.fill", verb: "quoted you")
        case "communitynote": return .init(color: DesignSystem.Color.secondaryLabel, symbol: "note.text", verb: "added a Community Note")
        default: return .init(color: DesignSystem.Color.accent, symbol: "bell.fill",
                              verb: rawType.replacingOccurrences(of: "_", with: " "))
        }
    }

    /// Bold actor names followed by the colored action verb.
    static func title(for notification: XNotification, style: NotifStyle) -> NSAttributedString {
        let names = notification.actors.prefix(2).map(\.name).joined(separator: ", ")
        let extra = notification.actors.count > 2 ? " +\(notification.actors.count - 2)" : ""
        let who = names.isEmpty ? "Someone" : names + extra
        let result = NSMutableAttributedString(string: who, attributes: [
            .font: DesignSystem.Typography.name(),
            .foregroundColor: DesignSystem.Color.label,
        ])
        result.append(NSAttributedString(string: " " + style.verb, attributes: [
            .font: DesignSystem.Typography.handle(),
            .foregroundColor: style.color,
        ]))
        return result
    }
}

extension NotificationsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
}

extension NotificationsViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("notifRow")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NotificationRowView
            ?? NotificationRowView(identifier: id)
        let notification = items[row]
        let style = Self.style(for: notification.type)
        cell.configure(chip: NotificationRowView.badge(symbol: style.symbol, color: style.color),
                       title: Self.title(for: notification, style: style),
                       secondary: notification.targetTweetSnippet,
                       time: Format.relativeTime(notification.timestamp),
                       showsDisclosure: notification.targetTweetID != nil)
        return cell
    }
}

/// A notification cell: a colored circular icon chip, bold actor names with a
/// colored action verb, the target-tweet snippet, and a relative timestamp.
private final class NotificationRowView: NSTableCellView {
    private let chipView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(wrappingLabelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let disclosure = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        chipView.imageScaling = .scaleNone
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        secondaryLabel.font = DesignSystem.Typography.metric()
        secondaryLabel.textColor = DesignSystem.Color.secondaryLabel
        secondaryLabel.maximumNumberOfLines = 2
        secondaryLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = DesignSystem.Typography.caption()
        timeLabel.textColor = DesignSystem.Color.tertiaryLabel
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        disclosure.image = DesignSystem.icon("chevron.right", pointSize: 11, weight: .semibold)
        disclosure.contentTintColor = DesignSystem.Color.tertiaryLabel
        disclosure.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = NSStackView(views: [titleLabel, NSView(), timeLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        let textColumn = NSStackView(views: [titleRow, secondaryLabel])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = DesignSystem.Spacing.xxs

        addManaged(chipView)
        addManaged(textColumn)
        addManaged(disclosure)
        NSLayoutConstraint.activate([
            chipView.widthAnchor.constraint(equalToConstant: 38),
            chipView.heightAnchor.constraint(equalToConstant: 38),
            chipView.topAnchor.constraint(equalTo: topAnchor, constant: DesignSystem.Spacing.m),
            chipView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignSystem.Spacing.l),
            textColumn.topAnchor.constraint(equalTo: topAnchor, constant: DesignSystem.Spacing.m),
            textColumn.leadingAnchor.constraint(equalTo: chipView.trailingAnchor, constant: DesignSystem.Spacing.m),
            textColumn.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignSystem.Spacing.m),
            disclosure.leadingAnchor.constraint(equalTo: textColumn.trailingAnchor, constant: DesignSystem.Spacing.s),
            disclosure.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignSystem.Spacing.l),
            disclosure.centerYAnchor.constraint(equalTo: chipView.centerYAnchor),
            titleRow.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
        ])
    }

    func configure(chip: NSImage?, title: NSAttributedString, secondary: String?, time: String, showsDisclosure: Bool) {
        chipView.image = chip
        titleLabel.attributedStringValue = title
        secondaryLabel.stringValue = secondary ?? ""
        secondaryLabel.isHidden = (secondary ?? "").isEmpty
        timeLabel.stringValue = time
        disclosure.isHidden = !showsDisclosure
    }

    /// A colored circular chip with the action glyph — the splash of color the
    /// flat list was missing.
    static func badge(symbol: String, color: NSColor) -> NSImage {
        let size = NSSize(width: 38, height: 38)
        let image = NSImage(size: size)
        image.lockFocus()
        color.withAlphaComponent(0.16).setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        if let glyph = DesignSystem.icon(symbol, pointSize: 17, weight: .semibold)?
            .tinted(with: color) {
            let glyphSize = glyph.size
            let rect = NSRect(x: (size.width - glyphSize.width) / 2,
                              y: (size.height - glyphSize.height) / 2,
                              width: glyphSize.width, height: glyphSize.height)
            glyph.draw(in: rect)
        }
        image.unlockFocus()
        return image
    }
}

private extension NSImage {
    /// Returns a copy of the (template) image painted in a solid color.
    func tinted(with color: NSColor) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        draw(in: rect)
        rect.fill(using: .sourceAtop)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }
}
