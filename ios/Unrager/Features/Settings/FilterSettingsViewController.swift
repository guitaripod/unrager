import UIKit
import UnragerKit

/// Edits the rage-filter rubric — the topics to drop and free-form guidance —
/// persisted server-side via `PATCH /api/config/filter`. The local classifier
/// (Ollama) on the server uses it to hide matching tweets.
final class FilterSettingsViewController: UIViewController {
    private let topicsView = UITextView()
    private let guidanceView = UITextView()
    private let modelLabel = UILabel()
    private lazy var saveButton = UIBarButtonItem(
        title: "Save", style: .done, target: self, action: #selector(save))

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Rage Filter"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.rightBarButtonItem = saveButton

        let stack = UIStackView(arrangedSubviews: [
            caption("DROP TOPICS — one per line. Tweets the local model judges to match are hidden."),
            boxed(topicsView, minHeight: 140),
            caption("EXTRA GUIDANCE — free-form instructions for the classifier."),
            boxed(guidanceView, minHeight: 100),
            modelLabel,
        ])
        stack.axis = .vertical
        stack.spacing = DesignSystem.Spacing.s
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 16, leading: 16, bottom: 16, trailing: 16)

        modelLabel.font = DesignSystem.Typography.caption()
        modelLabel.textColor = DesignSystem.Color.secondaryLabel
        modelLabel.numberOfLines = 0

        view.addManaged(stack)
        stack.pinEdges(toSafeAreaOf: view)
        load()
    }

    private func boxed(_ textView: UITextView, minHeight: CGFloat) -> UIView {
        textView.font = DesignSystem.Typography.body()
        textView.backgroundColor = DesignSystem.Color.surface
        textView.textColor = DesignSystem.Color.label
        textView.layer.cornerRadius = DesignSystem.Radius.control
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = .init(top: 10, left: 8, bottom: 10, right: 8)
        textView.autocapitalizationType = .none
        textView.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        return textView
    }

    private func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = DesignSystem.Typography.caption()
        label.textColor = DesignSystem.Color.secondaryLabel
        label.numberOfLines = 0
        return label
    }

    private func load() {
        Task {
            do {
                let config = try await AppEnvironment.shared.api.filterConfig()
                topicsView.text = config.dropTopics.joined(separator: "\n")
                guidanceView.text = config.extraGuidance
                if let ollama = config.ollama {
                    modelLabel.text = "Classifier: \(ollama.model) @ \(ollama.host)"
                }
            } catch {
                present(AlertFactory.error(error), animated: true)
            }
        }
    }

    @objc private func save() {
        let topics = topicsView.text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let guidance = guidanceView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        saveButton.isEnabled = false
        Task {
            do {
                _ = try await AppEnvironment.shared.api.patchFilterConfig(
                    FilterPatch(dropTopics: topics, extraGuidance: guidance))
                Haptics.success()
                navigationController?.popViewController(animated: true)
            } catch {
                saveButton.isEnabled = true
                present(AlertFactory.error(error), animated: true)
            }
        }
    }
}
