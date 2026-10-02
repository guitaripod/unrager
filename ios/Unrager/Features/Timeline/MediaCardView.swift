import UIKit
import UnragerKit

/// A bordered, tap-through preview card for the non-image media kinds —
/// link cards, articles, broadcasts and YouTube. Shows an optional cover image
/// (drawn whole: a frame of the cover's usual shape, with a frosted copy of the
/// picture filling what a differently shaped cover leaves), a title, a context
/// line (domain / broadcaster / preview text), and one of two overlays: a
/// "● LIVE" pill for a live broadcast, a play glyph for YouTube. Tapping invokes `onTap` (the cell routes it to a browser open).
final class MediaCardView: UIView {
    var onTap: (() -> Void)?

    private let tapGesture = UITapGestureRecognizer()
    private let coverBox = UIView()
    private let backdrop = AmbientBackdropView(frame: .zero)
    private let cover = AsyncImageView(frame: .zero)
    private var coverRatio = MediaShape.largeCover
    private var coverKey: String?
    private let livePill = UILabel()
    private let playBadge = UIImageView()
    private let domainLabel = UILabel()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let textColumn = UIStackView()
    private var coverHeight: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = DesignSystem.Radius.media
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = DesignSystem.Color.separator.cgColor
        clipsToBounds = true
        isUserInteractionEnabled = true
        tapGesture.addTarget(self, action: #selector(tapped))
        addGestureRecognizer(tapGesture)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MediaCardView, _) in
            view.layer.borderColor = DesignSystem.Color.separator.cgColor
        }

        coverBox.clipsToBounds = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        coverBox.addSubview(backdrop)
        backdrop.pinEdges(to: coverBox)
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.contentMode = .scaleAspectFill
        cover.fadesIn = true
        cover.onLoad = { [weak self] image in self?.fit(to: image) }
        coverBox.addSubview(cover)
        cover.pinEdges(to: coverBox)
        letConstraintDriveCoverHeight()

        livePill.text = "● LIVE"
        livePill.font = DesignSystem.Typography.system(11, weight: .heavy)
        livePill.textColor = .white
        livePill.backgroundColor = DesignSystem.Color.live
        livePill.textAlignment = .center
        livePill.layer.cornerRadius = 4
        livePill.layer.masksToBounds = true
        livePill.translatesAutoresizingMaskIntoConstraints = false
        livePill.isHidden = true

        playBadge.image = DesignSystem.icon("play.circle.fill", pointSize: 40)
        playBadge.tintColor = .white
        playBadge.translatesAutoresizingMaskIntoConstraints = false
        playBadge.isHidden = true

        domainLabel.font = DesignSystem.Typography.caption()
        domainLabel.textColor = DesignSystem.Color.secondaryLabel
        titleLabel.font = DesignSystem.Typography.name()
        titleLabel.textColor = DesignSystem.Color.label
        titleLabel.numberOfLines = 2
        detailLabel.font = DesignSystem.Typography.metric()
        detailLabel.textColor = DesignSystem.Color.secondaryLabel
        detailLabel.numberOfLines = 2

        textColumn.axis = .vertical
        textColumn.spacing = 2
        textColumn.isLayoutMarginsRelativeArrangement = true
        textColumn.directionalLayoutMargins = .init(top: 10, leading: 12, bottom: 10, trailing: 12)
        textColumn.addArrangedSubview(domainLabel)
        textColumn.addArrangedSubview(titleLabel)
        textColumn.addArrangedSubview(detailLabel)

        let column = UIStackView(arrangedSubviews: [coverBox, textColumn])
        column.axis = .vertical
        column.spacing = 0
        addManaged(column)
        column.pinEdges(to: self)
        coverBox.addManaged(playBadge)
        coverBox.addManaged(livePill)

        let height = coverBox.heightAnchor.constraint(equalToConstant: 160)
        height.priority = .defaultHigh
        height.isActive = true
        coverHeight = height
        NSLayoutConstraint.activate([
            playBadge.centerXAnchor.constraint(equalTo: coverBox.centerXAnchor),
            playBadge.centerYAnchor.constraint(equalTo: coverBox.centerYAnchor),
            livePill.topAnchor.constraint(equalTo: coverBox.topAnchor, constant: 8),
            livePill.leadingAnchor.constraint(equalTo: coverBox.leadingAnchor, constant: 8),
            livePill.widthAnchor.constraint(equalToConstant: 52),
            livePill.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    /// The cover's height comes from its constraint (the width over its ratio),
    /// not from the loaded image. With default priorities the image view's
    /// intrinsic height ties with that constraint and wins after an async or
    /// prefetched load, over-reserving space and leaving a gap above the labels.
    private func letConstraintDriveCoverHeight() {
        cover.setContentHuggingPriority(.defaultLow, for: .vertical)
        cover.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        coverBox.setContentHuggingPriority(.defaultLow, for: .vertical)
        coverBox.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    struct Model {
        let domain: String?
        let title: String
        let detail: String?
        let coverURL: URL?
        let isLive: Bool
        let isPlayable: Bool
        /// The shape cards of this kind usually have; a cover of another
        /// shape is shown whole inside it.
        var coverRatio: CGFloat = MediaShape.largeCover
    }

    /// The cover's size in a card `contentWidth` wide.
    static func coverSize(contentWidth: CGFloat, ratio: CGFloat = MediaShape.largeCover) -> CGSize {
        CGSize(width: contentWidth, height: (contentWidth / ratio).rounded())
    }

    /// Whether the card opens something when tapped. Without a destination it
    /// takes no taps, so a tap on it reaches the post under it instead of
    /// going nowhere.
    func setOpensLink(_ opens: Bool) {
        tapGesture.isEnabled = opens
        accessibilityTraits = opens ? .link : .staticText
    }

    func configure(_ model: Model, contentWidth: CGFloat, imagesEnabled: Bool) {
        domainLabel.text = model.domain?.uppercased()
        domainLabel.isHidden = (model.domain ?? "").isEmpty
        titleLabel.text = model.title
        titleLabel.isHidden = model.title.isEmpty
        detailLabel.text = model.detail
        detailLabel.isHidden = (model.detail ?? "").isEmpty
        livePill.isHidden = !model.isLive
        playBadge.isHidden = !model.isPlayable

        coverRatio = model.coverRatio
        if imagesEnabled, let url = model.coverURL {
            coverBox.isHidden = false
            let size = Self.coverSize(contentWidth: contentWidth, ratio: model.coverRatio)
            coverHeight?.constant = size.height
            coverKey = url.absoluteString
            cover.load(url: url, targetSize: size)
        } else {
            coverBox.isHidden = true
            cover.cancel()
            backdrop.clear()
        }

        isAccessibilityElement = true
        let prefix = model.isLive ? "Live broadcast. " : (model.isPlayable ? "Video. " : "Link. ")
        accessibilityLabel = prefix + model.title + (model.detail.map { ". \($0)" } ?? "")
    }

    func prepareForReuse() {
        cover.cancel()
        backdrop.clear()
        onTap = nil
    }

    /// Fills the cover's frame with the picture when it is that shape, and
    /// otherwise shows it whole over a frosted copy of itself.
    private func fit(to image: UIImage) {
        let fills = MediaShape.matches(image.size, in: CGSize(width: coverRatio, height: 1))
        cover.contentMode = fills ? .scaleAspectFill : .scaleAspectFit
        if fills {
            backdrop.clear()
        } else if let url = coverKey {
            backdrop.show(from: image, key: url)
        }
    }

    @objc private func tapped() { onTap?() }

}
