import UIKit
import UnragerKit

/// A Liquid Glass toast dropped from the top of the screen when activity
/// arrives while the app is foregrounded — the in-app counterpart to a system
/// banner, needing no notification permission. It carries the action badge,
/// who did what, and the target snippet; slides in with a spring, auto-dismisses
/// after a few seconds, and deep-links on tap.
final class NotificationToast: UIView {
    private let onTap: () -> Void
    private var dismissWork: DispatchWorkItem?
    private var topConstraint: NSLayoutConstraint?

    init(badge: UIImage, title: String, subtitle: String?, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        build(badge: badge, title: title, subtitle: subtitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build(badge: UIImage, title: String, subtitle: String?) {
        let glass = UIVisualEffectView.glass()
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.setFixedCorners(DesignSystem.Radius.card)
        glass.clipsToBounds = true
        addSubview(glass)
        glass.pinEdges(to: self)

        let icon = UIImageView(image: badge)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = UILabel()
        titleLabel.font = DesignSystem.Typography.name()
        titleLabel.textColor = DesignSystem.Color.label
        titleLabel.text = title
        titleLabel.numberOfLines = 1

        let textStack = UIStackView(arrangedSubviews: [titleLabel])
        textStack.axis = .vertical
        textStack.spacing = 1
        if let subtitle, !subtitle.isEmpty {
            let sub = UILabel()
            sub.font = DesignSystem.Typography.handle()
            sub.textColor = DesignSystem.Color.secondaryLabel
            sub.text = subtitle
            sub.numberOfLines = 1
            sub.lineBreakMode = .byTruncatingTail
            textStack.addArrangedSubview(sub)
        }

        let row = UIStackView(arrangedSubviews: [icon, textStack])
        row.axis = .horizontal
        row.spacing = DesignSystem.Spacing.m
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 38),
            icon.heightAnchor.constraint(equalToConstant: 38),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: DesignSystem.Spacing.s),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -DesignSystem.Spacing.l),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: DesignSystem.Spacing.s),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -DesignSystem.Spacing.s),
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    /// Drops the toast in from above the safe area, springs it to rest, and arms
    /// the auto-dismiss. Replaces any toast already on screen in `host`.
    func present(in host: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        let top = topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: DesignSystem.Spacing.s)
        topConstraint = top
        NSLayoutConstraint.activate([
            top,
            leadingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.leadingAnchor, constant: DesignSystem.Spacing.m),
            trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -DesignSystem.Spacing.m),
        ])
        host.layoutIfNeeded()

        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: -(bounds.height + DesignSystem.Spacing.xl))
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.4) {
            self.alpha = 1
            self.transform = .identity
        }
        Haptics.selection()
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    func dismiss() {
        dismissWork?.cancel()
        UIView.animate(withDuration: 0.3, animations: {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: -(self.bounds.height + DesignSystem.Spacing.xl))
        }, completion: { _ in self.removeFromSuperview() })
    }

    @objc private func handleTap() {
        onTap()
        dismiss()
    }
}
