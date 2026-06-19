import AppKit

/// The source a sidebar row selects.
enum SidebarItem: Int, CaseIterable {
    case forYou
    case following
    case search
    case mentions
    case bookmarks
    case notifications
    case settings

    var title: String {
        switch self {
        case .forYou: return "For You"
        case .following: return "Following"
        case .search: return "Search"
        case .mentions: return "Mentions"
        case .bookmarks: return "Bookmarks"
        case .notifications: return "Notifications"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .forYou: return "sparkles"
        case .following: return "person.2"
        case .search: return "magnifyingglass"
        case .mentions: return "at"
        case .bookmarks: return "bookmark"
        case .notifications: return "bell"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
protocol SidebarDelegate: AnyObject {
    func sidebar(didSelect item: SidebarItem)
}

/// The source list on the leading edge of the window: a glass-backed table of
/// selectable sources.
@MainActor
final class SidebarViewController: NSViewController {
    weak var delegate: (any SidebarDelegate)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let items = SidebarItem.allCases

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureTable()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .sourceList
        tableView.rowHeight = 32
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = false

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        view.addManaged(scrollView)
        scrollView.pinEdges(to: view)
    }

    func select(_ item: SidebarItem) {
        tableView.selectRowIndexes(IndexSet(integer: item.rawValue), byExtendingSelection: false)
    }
}

extension SidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
}

extension SidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("sidebarCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id: id)
        let item = items[row]
        cell.textField?.stringValue = item.title
        cell.imageView?.image = DesignSystem.icon(item.symbol, pointSize: 15)
        cell.imageView?.contentTintColor = DesignSystem.Color.accent
        return cell
    }

    private func makeCell(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let imageView = NSImageView()
        let textField = NSTextField(labelWithString: "")
        textField.font = .systemFont(ofSize: 13, weight: .medium)
        textField.textColor = DesignSystem.Color.label
        cell.imageView = imageView
        cell.textField = textField
        cell.addManaged(imageView)
        cell.addManaged(textField)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: DesignSystem.Spacing.s),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 20),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: DesignSystem.Spacing.s),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -DesignSystem.Spacing.s),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        delegate?.sidebar(didSelect: items[row])
    }
}
