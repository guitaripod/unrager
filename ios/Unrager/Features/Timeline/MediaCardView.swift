import UIKit
import UnragerKit

/// A bordered, tap-through preview card for the non-image media kinds —
/// link cards, articles, broadcasts and YouTube. Shows an optional cover image,
/// a title, a context line (domain / broadcaster / preview text), and one of
/// two overlays: a "● LIVE" pill for a live broadcast, a play glyph for
/// YouTube. Tapping invokes `onTap` (the cell routes it to a browser open).
final class MediaCardView: UIView {
    var onTap: (() -> Void)?

    private let cover = AsyncImageView(frame: .zero)
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
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.contentMode = .scaleAspectFill

        livePill.text = "● LIVE"
        livePill.font = .systemFont(ofSize: 11, weight: .heavy)
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

        let column = UIStackView(arrangedSubviews: [cover, textColumn])
        column.axis = .vertical
        column.spacing = 0
        addManaged(column)
        column.pinEdges(to: self)
        cover.addManaged(playBadge)
        cover.addManaged(livePill)

        let height = cover.heightAnchor.constraint(equalToConstant: 160)
        height.priority = .defaultHigh
        height.isActive = true
        coverHeight = height
        NSLayoutConstraint.activate([
            playBadge.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            playBadge.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            livePill.topAnchor.constraint(equalTo: cover.topAnchor, constant: 8),
            livePill.leadingAnchor.constraint(equalTo: cover.leadingAnchor, constant: 8),
            livePill.widthAnchor.constraint(equalToConstant: 52),
            livePill.heightAnchor.constraint(equalToConstant: 20),
        ])
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

        if imagesEnabled, let url = model.coverURL {
            cover.isHidden = false
            let height = (contentWidth * 0.52).rounded()
            coverHeight?.constant = height
            cover.load(url: url, targetSize: CGSize(width: contentWidth, height: height))
        } else {
            cover.isHidden = true
            cover.cancel()
        }

        isAccessibilityElement = true
        accessibilityTraits = .link
        let prefix = model.isLive ? "Live broadcast. " : (model.isPlayable ? "Video. " : "Link. ")
        accessibilityLabel = prefix + model.title + (model.detail.map { ". \($0)" } ?? "")
    }

    func prepareForReuse() {
        cover.cancel()
        onTap = nil
    }

    @objc private func tapped() { onTap?() }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        layer.borderColor = DesignSystem.Color.separator.cgColor
    }
}
