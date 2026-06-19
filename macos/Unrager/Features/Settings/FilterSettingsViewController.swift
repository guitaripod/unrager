import AppKit
import UnragerKit

/// Edits the rage-filter rubric — the topics to drop and free-form guidance —
/// persisted server-side via `PATCH /api/config/filter`. The local classifier
/// (Ollama) on the server uses it to hide matching tweets. Mirrors the iOS
/// `FilterSettingsViewController`.
@MainActor
final class FilterSettingsViewController: NSViewController {
    private let api = AppEnvironment.shared.api

    private let topicsView = NSTextView()
    private let topicsScroll = NSScrollView()
    private let guidanceView = NSTextView()
    private let guidanceScroll = NSScrollView()
    private let modelLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let closeButton = NSButton(title: "Done", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let container = BackgroundView(color: DesignSystem.Color.windowBackground)
        container.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Rage Filter"
        build()
        load()
    }

    private func build() {
        let titleLabel = NSTextField(labelWithString: "Rage Filter")
        titleLabel.font = DesignSystem.Typography.title()
        titleLabel.textColor = DesignSystem.Color.label

        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.target = self
        closeButton.action = #selector(close)

        let topicsCaption = caption("Drop topics — one per line. Tweets the local model judges to match are hidden.")
        configureBox(topicsView, scroll: topicsScroll, minHeight: 160)
        let guidanceCaption = caption("Extra guidance — free-form instructions for the classifier.")
        configureBox(guidanceView, scroll: guidanceScroll, minHeight: 110)

        modelLabel.font = DesignSystem.Typography.metric()
        modelLabel.textColor = DesignSystem.Color.secondaryLabel
        modelLabel.maximumNumberOfLines = 2

        statusLabel.font = DesignSystem.Typography.metric()
        statusLabel.textColor = DesignSystem.Color.secondaryLabel
        statusLabel.stringValue = ""

        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.contentTintColor = DesignSystem.Color.accent

        let footer = NSStackView(views: [statusLabel, NSView(), closeButton, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = DesignSystem.Spacing.s

        let column = NSStackView(views: [
            titleLabel,
            topicsCaption, topicsScroll,
            guidanceCaption, guidanceScroll,
            modelLabel,
            footer,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = DesignSystem.Spacing.s

        view.addManaged(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: DesignSystem.Spacing.xl),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: DesignSystem.Spacing.xl),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -DesignSystem.Spacing.xl),
            column.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -DesignSystem.Spacing.xl),
            topicsScroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            guidanceScroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            footer.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    @objc private func close() {
        dismiss(self)
    }

    private func configureBox(_ textView: NSTextView, scroll: NSScrollView, minHeight: CGFloat) {
        textView.font = DesignSystem.Typography.body()
        textView.textColor = DesignSystem.Color.label
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = DesignSystem.Color.surface
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = DesignSystem.Radius.control
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.masksToBounds = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = DesignSystem.Typography.caption()
        label.textColor = DesignSystem.Color.secondaryLabel
        return label
    }

    private func load() {
        Task {
            do {
                let config = try await api.filterConfig()
                topicsView.string = config.dropTopics.joined(separator: "\n")
                guidanceView.string = config.extraGuidance
                if let ollama = config.ollama {
                    modelLabel.stringValue = "Classifier: \(ollama.model) @ \(ollama.host)"
                }
            } catch {
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func save() {
        let topics = topicsView.string
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let guidance = guidanceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        saveButton.isEnabled = false
        statusLabel.textColor = DesignSystem.Color.secondaryLabel
        statusLabel.stringValue = "Saving…"
        Task {
            do {
                _ = try await api.patchFilterConfig(FilterPatch(dropTopics: topics, extraGuidance: guidance))
                statusLabel.textColor = DesignSystem.Color.retweet
                statusLabel.stringValue = "Saved"
                saveButton.isEnabled = true
            } catch {
                saveButton.isEnabled = true
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = error.localizedDescription
            }
        }
    }
}
