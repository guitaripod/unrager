import UIKit
import UnragerKit

/// Edits the rage-filter rubric — the topics to drop, free-form guidance and how
/// strict the filter is — persisted server-side via `PATCH /api/config/filter`.
/// The model on the server uses it to hide matching tweets. The editor stays
/// locked until the server's current rubric has loaded, so saving can never
/// replace it with an empty one, and leaving with unsaved edits asks first (the
/// custom Cancel button also switches off the swipe-back that would skip that).
final class FilterSettingsViewController: UIViewController {
    private let scrollView = UIScrollView()
    private let topicsView = UITextView()
    private let guidanceView = UITextView()
    private let strictnessControl = UISegmentedControl(items: FilterStrictness.allCases.map(\.title))
    private let strictnessSummary = UILabel()
    private let strictnessGroup = UIStackView()
    private let builtInLabel = UILabel()
    private let modelLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private lazy var saveButton = UIBarButtonItem(
        title: "Save", style: .prominent, target: self, action: #selector(save))
    private lazy var cancelButton = UIBarButtonItem(
        title: "Cancel", style: .plain, target: self, action: #selector(cancel))

    private var loaded: (topics: String, guidance: String, strictness: FilterStrictness?)?

    private var selectedStrictness: FilterStrictness? {
        guard !strictnessGroup.isHidden else { return nil }
        return FilterStrictness.allCases[strictnessControl.selectedSegmentIndex]
    }

    private var isDirty: Bool {
        guard let loaded else { return false }
        return topicsView.text != loaded.topics || guidanceView.text != loaded.guidance
            || selectedStrictness != loaded.strictness
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Rage Filter"
        view.backgroundColor = DesignSystem.Color.background
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = cancelButton
        navigationItem.rightBarButtonItem = saveButton
        saveButton.isEnabled = false

        strictnessControl.addTarget(self, action: #selector(strictnessChanged), for: .valueChanged)
        strictnessControl.accessibilityLabel = "Strictness"
        strictnessSummary.font = DesignSystem.Typography.caption()
        strictnessSummary.textColor = DesignSystem.Color.secondaryLabel
        strictnessSummary.numberOfLines = 0
        strictnessGroup.axis = .vertical
        strictnessGroup.spacing = DesignSystem.Spacing.s
        strictnessGroup.addArrangedSubview(caption("STRICTNESS"))
        strictnessGroup.addArrangedSubview(strictnessControl)
        strictnessGroup.addArrangedSubview(strictnessSummary)
        strictnessGroup.isHidden = true

        for label in [builtInLabel, modelLabel] {
            label.font = DesignSystem.Typography.caption()
            label.textColor = DesignSystem.Color.secondaryLabel
            label.numberOfLines = 0
        }
        builtInLabel.isHidden = true

        let stack = UIStackView(arrangedSubviews: [
            strictnessGroup,
            caption("DROP TOPICS — one per line. Tweets the model judges to match are hidden."),
            boxed(topicsView, minHeight: 140, label: "Drop topics"),
            caption("EXTRA GUIDANCE — free-form instructions for the classifier."),
            boxed(guidanceView, minHeight: 100, label: "Extra guidance"),
            builtInLabel,
            modelLabel,
        ])
        stack.axis = .vertical
        stack.spacing = DesignSystem.Spacing.s
        stack.setCustomSpacing(DesignSystem.Spacing.xl, after: strictnessGroup)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 16, leading: 16, bottom: 16, trailing: 16)

        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        view.addManaged(scrollView)
        scrollView.addManaged(stack)
        view.addManaged(loadingIndicator)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        setEditable(false)
        load()
    }

    private func boxed(_ textView: UITextView, minHeight: CGFloat, label: String) -> UIView {
        textView.font = DesignSystem.Typography.body()
        textView.backgroundColor = DesignSystem.Color.surface
        textView.textColor = DesignSystem.Color.label
        textView.layer.cornerRadius = DesignSystem.Radius.control
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = .init(top: 10, left: 8, bottom: 10, right: 8)
        textView.autocapitalizationType = .none
        textView.isScrollEnabled = false
        textView.accessibilityLabel = label
        textView.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        textView.delegate = self
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

    private func setEditable(_ editable: Bool) {
        topicsView.isEditable = editable
        guidanceView.isEditable = editable
        strictnessControl.isEnabled = editable
        topicsView.alpha = editable ? 1 : 0.5
        guidanceView.alpha = editable ? 1 : 0.5
    }

    private func load() {
        loadingIndicator.startAnimating()
        Task {
            defer { loadingIndicator.stopAnimating() }
            do {
                let config = try await AppEnvironment.shared.api.filterConfig()
                apply(config)
            } catch {
                presentLoadFailure(error)
            }
        }
    }

    private func apply(_ config: FilterConfig) {
        topicsView.text = config.dropTopics.joined(separator: "\n")
        guidanceView.text = config.extraGuidance
        if let strictness = config.strictness {
            strictnessControl.selectedSegmentIndex = FilterStrictness.allCases.firstIndex(of: strictness) ?? 1
            strictnessSummary.text = strictness.summary
            strictnessGroup.isHidden = false
        }
        if !config.builtInRules.isEmpty {
            builtInLabel.text = "BUILT-IN RULES (not under Relaxed)\n" + config.builtInRules.map { "• \($0)" }.joined(separator: "\n")
            builtInLabel.isHidden = false
        }
        if let ollama = config.ollama {
            modelLabel.text = "Classifier: \(ollama.model) @ \(ollama.host)"
        }
        loaded = (topicsView.text, guidanceView.text, config.strictness)
        setEditable(true)
        refreshSaveState()
    }

    private func presentLoadFailure(_ error: any Error) {
        let alert = UIAlertController(
            title: "Couldn't load the filter",
            message: error.localizedDescription,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in self?.load() })
        alert.addAction(UIAlertAction(title: "Back", style: .cancel) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }

    private func refreshSaveState() {
        saveButton.isEnabled = loaded != nil && isDirty
    }

    @objc private func strictnessChanged() {
        if let strictness = selectedStrictness { strictnessSummary.text = strictness.summary }
        Haptics.selection()
        refreshSaveState()
    }

    /// Leaves the screen, asking first when there are edits that would be lost.
    @objc private func cancel() {
        guard isDirty else {
            navigationController?.popViewController(animated: true)
            return
        }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Discard Changes", style: .destructive) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = cancelButton
        present(sheet, animated: true)
    }

    @objc private func save() {
        guard loaded != nil else { return }
        let topics = topicsView.text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let guidance = guidanceView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        saveButton.isEnabled = false
        view.endEditing(true)
        Task {
            do {
                _ = try await AppEnvironment.shared.api.patchFilterConfig(
                    FilterPatch(dropTopics: topics, extraGuidance: guidance, strictness: selectedStrictness))
                Haptics.success()
                NotificationCenter.default.post(name: AppSettings.filterRulesDidChange, object: nil)
                navigationController?.popViewController(animated: true)
            } catch {
                refreshSaveState()
                present(AlertFactory.error(error, title: "Couldn't save"), animated: true)
            }
        }
    }
}

extension FilterSettingsViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        refreshSaveState()
    }
}
