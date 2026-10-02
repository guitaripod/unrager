import UIKit
import UnragerKit

/// The leading mark of a notification row: one face, or a cluster of up to three
/// with the action's chip (heart, reply, …) filling the corner a face leaves
/// free. A cluster stands for a group, so tapping it asks for the people behind
/// it; a lone face asks for that person. A notification with no people shows
/// its chip alone, large. Faces are ringed in the row's own colour so they stay
/// apart where they overlap.
final class NotificationAvatarStackView: UIControl {
    static let side: CGFloat = 56
    static let maxFaces = 3

    private static let chipDiameter: CGFloat = 22
    private static let chipRing: CGFloat = 2

    private var key: String?
    private var avatarTasks: [Task<Void, Never>] = []

    override var intrinsicContentSize: CGSize { CGSize(width: Self.side, height: Self.side) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIgnoresInvertColors = true
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    /// Where each face sits, by how many there are: the chip's corner is left
    /// clear in every arrangement.
    private struct Cluster {
        let diameter: CGFloat
        let origins: [CGPoint]
        let chipOrigin: CGPoint

        static func make(faces: Int) -> Cluster {
            let holder = chipDiameter + chipRing * 2
            let far = side - holder
            switch faces {
            case 1:
                return Cluster(diameter: 46, origins: [CGPoint(x: 0, y: 5)], chipOrigin: CGPoint(x: far, y: far))
            case 2:
                return Cluster(diameter: 34, origins: [CGPoint(x: 0, y: 0), CGPoint(x: 22, y: 22)],
                               chipOrigin: CGPoint(x: 0, y: far))
            default:
                return Cluster(diameter: 30, origins: [CGPoint(x: 0, y: 0), CGPoint(x: 26, y: 0), CGPoint(x: 0, y: 26)],
                               chipOrigin: CGPoint(x: far, y: far))
            }
        }
    }

    /// Draws the mark for `actors`. Configuring the same people in the same
    /// style and ring colour again leaves the faces as they are, so a read mark
    /// or a like count refreshing a row never reloads its pictures.
    func configure(actors: [NotificationActor], style: NotificationStyle, ring: UIColor) {
        let shown = Array(actors.prefix(Self.maxFaces))
        let newKey = shown.map(\.restID).joined(separator: ",") + "|\(style.symbol)|\(ring.hash)|\(AppSettings.imagesEnabled)"
        guard newKey != key else { return }
        key = newKey
        clear()
        guard !shown.isEmpty else {
            let chip = UIImageView(image: style.badge(diameter: 44, glyphSize: 19))
            chip.frame = CGRect(x: 6, y: 6, width: 44, height: 44)
            addSubview(chip)
            return
        }
        let cluster = Cluster.make(faces: shown.count)
        for (index, actor) in shown.enumerated() {
            let face = makeFace(for: actor, diameter: cluster.diameter, tint: style.color, ring: ring)
            face.frame = CGRect(origin: cluster.origins[index],
                                size: CGSize(width: cluster.diameter, height: cluster.diameter))
            addSubview(face)
        }
        addSubview(makeChip(style: style, ring: ring, origin: cluster.chipOrigin))
    }

    func prepareForReuse() {
        clear()
        key = nil
    }

    private func clear() {
        avatarTasks.forEach { $0.cancel() }
        avatarTasks.removeAll()
        subviews.forEach { $0.removeFromSuperview() }
    }

    /// A round face on a tinted stand-in, swapped for the real picture as soon
    /// as it is in memory or loaded; ringed so overlapping faces stay apart.
    private func makeFace(for actor: NotificationActor, diameter: CGFloat, tint: UIColor, ring: UIColor) -> UIImageView {
        let face = UIImageView()
        face.isUserInteractionEnabled = false
        face.contentMode = .scaleAspectFill
        face.clipsToBounds = true
        face.backgroundColor = tint.withAlphaComponent(0.16)
        face.layer.cornerRadius = diameter / 2
        face.layer.cornerCurve = .continuous
        face.layer.borderWidth = 2
        face.layer.borderColor = ring.resolvedColor(with: traitCollection).cgColor
        guard AppSettings.imagesEnabled, let url = actor.avatarURL.flatMap(URL.init) else { return face }
        let size = CGSize(width: diameter, height: diameter)
        let scale = max(traitCollection.displayScale, 1)
        if let hit = ImageLoader.cachedImageImmediately(for: url, pointSize: size, scale: scale) {
            face.image = hit
            face.backgroundColor = .clear
            return face
        }
        avatarTasks.append(Task { [weak face] in
            let image = await ImageLoader.image(for: url, pointSize: size, scale: scale)
            guard !Task.isCancelled, let face, let image else { return }
            face.image = image
            face.backgroundColor = .clear
        })
        return face
    }

    private func makeChip(style: NotificationStyle, ring: UIColor, origin: CGPoint) -> UIView {
        let holderSize = Self.chipDiameter + Self.chipRing * 2
        let holder = UIView(frame: CGRect(origin: origin, size: CGSize(width: holderSize, height: holderSize)))
        holder.backgroundColor = ring
        holder.layer.cornerRadius = holderSize / 2
        holder.isUserInteractionEnabled = false
        let chip = UIImageView(image: style.badge(diameter: Self.chipDiameter, glyphSize: 11))
        chip.frame = CGRect(x: Self.chipRing, y: Self.chipRing, width: Self.chipDiameter, height: Self.chipDiameter)
        holder.addSubview(chip)
        return holder
    }

    deinit {
        avatarTasks.forEach { $0.cancel() }
    }
}
