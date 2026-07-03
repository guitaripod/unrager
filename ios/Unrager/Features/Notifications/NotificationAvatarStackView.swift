import UIKit
import UnragerKit

/// The leading accessory for a notification row: up to three overlapping actor
/// avatars with the action chip (heart, reply, …) badged over the bottom-right
/// corner — how grouped activity reads at a glance on X. Every avatar is a
/// button that opens that actor's profile. Frame-based because cell-accessory
/// custom views size via their frame.
final class NotificationAvatarStackView: UIView {
    static let maxAvatars = 3
    private static let singleDiameter: CGFloat = 38
    private static let stackedDiameter: CGFloat = 28
    private static let overlapStep: CGFloat = 12
    private static let chipDiameter: CGFloat = 20
    private static let height: CGFloat = 44

    private let onTapActor: (NotificationActor) -> Void

    static func size(for actorCount: Int) -> CGSize {
        let shown = max(1, min(actorCount, maxAvatars))
        let diameter = shown == 1 ? singleDiameter : stackedDiameter
        let span = diameter + overlapStep * CGFloat(shown - 1)
        return CGSize(width: span, height: height)
    }

    init(actors: [NotificationActor], chip: UIImage?, accentColor: UIColor,
         onTapActor: @escaping (NotificationActor) -> Void) {
        self.onTapActor = onTapActor
        let size = Self.size(for: actors.count)
        super.init(frame: CGRect(origin: .zero, size: size))
        build(actors: actors, chip: chip, accentColor: accentColor, size: size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build(actors: [NotificationActor], chip: UIImage?, accentColor: UIColor, size: CGSize) {
        let shown = Array(actors.prefix(Self.maxAvatars))
        let diameter = shown.count <= 1 ? Self.singleDiameter : Self.stackedDiameter
        let y = (Self.height - diameter) / 2
        for (index, actor) in shown.enumerated() {
            let button = avatarButton(for: actor, diameter: diameter, accentColor: accentColor)
            button.frame = CGRect(x: Self.overlapStep * CGFloat(index), y: y,
                                  width: diameter, height: diameter)
            addSubview(button)
        }
        if shown.isEmpty {
            let placeholder = UIImageView(image: chip)
            placeholder.frame = CGRect(x: (size.width - Self.singleDiameter) / 2,
                                       y: (Self.height - Self.singleDiameter) / 2,
                                       width: Self.singleDiameter, height: Self.singleDiameter)
            addSubview(placeholder)
            return
        }
        if let chip {
            let chipView = UIImageView(image: chip)
            chipView.frame = CGRect(x: size.width - Self.chipDiameter + 2,
                                    y: Self.height - Self.chipDiameter,
                                    width: Self.chipDiameter, height: Self.chipDiameter)
            chipView.isUserInteractionEnabled = false
            addSubview(chipView)
        }
    }

    /// A circular avatar button, ringed with the row background so overlapped
    /// faces stay separated. Starts on a tinted placeholder and swaps in the
    /// real avatar asynchronously (cache-fast in practice).
    private func avatarButton(for actor: NotificationActor, diameter: CGFloat,
                              accentColor: UIColor) -> UIButton {
        let button = UIButton(type: .custom)
        button.backgroundColor = accentColor.withAlphaComponent(0.14)
        button.layer.cornerRadius = diameter / 2
        button.layer.borderWidth = 1.5
        button.layer.borderColor = DesignSystem.Color.background.cgColor
        button.clipsToBounds = true
        button.imageView?.contentMode = .scaleAspectFill
        button.contentHorizontalAlignment = .fill
        button.contentVerticalAlignment = .fill
        button.accessibilityLabel = "\(actor.name), view profile"
        button.addAction(UIAction { [weak self] _ in
            Haptics.selection()
            self?.onTapActor(actor)
        }, for: .touchUpInside)
        if AppSettings.imagesEnabled, let url = actor.avatarURL.flatMap(URL.init) {
            Task { [weak button] in
                let image = await ImageLoader.image(
                    for: url, pointSize: CGSize(width: diameter, height: diameter), scale: 3)
                guard let button, let image else { return }
                button.setImage(image, for: .normal)
            }
        }
        return button
    }
}
