import UIKit
import UnragerKit

/// A few overlapping faces, the first on top, each ringed in the page colour so
/// they stay apart where they meet.
final class FacePileView: UIView {
    static let diameter: CGFloat = 22
    private static let step: CGFloat = 15
    private static let border: CGFloat = 1.5

    private var key = ""
    private var faces: [AsyncImageView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: FacePileView, _) in
            let border = DesignSystem.Color.background.resolvedColor(with: view.traitCollection).cgColor
            view.faces.forEach { $0.layer.borderColor = border }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        guard !faces.isEmpty else { return CGSize(width: 0, height: Self.diameter) }
        return CGSize(width: Self.step * CGFloat(faces.count - 1) + Self.diameter, height: Self.diameter)
    }

    /// Shows `people`. The same people again leave the faces as they are, so a
    /// refresh that only moved a count never reloads a picture.
    func configure(people: [UserRow], tint: UIColor) {
        let newKey = people.map(\.id).joined(separator: ",") + "|\(AppSettings.imagesEnabled)"
        guard newKey != key else { return }
        key = newKey
        faces.forEach { $0.removeFromSuperview() }
        faces = people.map { makeFace($0, tint: tint) }
        for (index, face) in faces.enumerated().reversed() {
            face.frame = CGRect(x: CGFloat(index) * Self.step, y: 0, width: Self.diameter, height: Self.diameter)
            addSubview(face)
        }
        invalidateIntrinsicContentSize()
    }

    private func makeFace(_ person: UserRow, tint: UIColor) -> AsyncImageView {
        let face = AsyncImageView(frame: .zero)
        face.placeholderColor = tint.withAlphaComponent(0.3)
        face.backgroundColor = face.placeholderColor
        face.setRounded(Self.diameter / 2)
        face.layer.borderWidth = Self.border
        face.layer.borderColor = DesignSystem.Color.background.resolvedColor(with: traitCollection).cgColor
        if AppSettings.imagesEnabled {
            face.load(url: person.avatarURL, targetSize: CGSize(width: Self.diameter, height: Self.diameter))
        }
        return face
    }
}
