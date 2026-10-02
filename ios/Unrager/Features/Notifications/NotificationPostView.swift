import UIKit
import UnragerKit

/// The post a notification is about, shown inside its row. Engagement shows the
/// user's own post as a quiet quoted card with a bar in the action's colour and
/// how many likes it has; a reply, mention or quote shows what the person wrote
/// in a bubble tinted with the action's colour. A photo or video from the post
/// sits at the trailing edge, a play mark on a clip.
final class NotificationPostView: UIView {
    enum Look { case quoted, bubble }

    private static let thumbSide: CGFloat = 52

    private let accentBar = UIView()
    private let textLabel = UILabel()
    private let metricsLabel = UILabel()
    private let thumb = AsyncImageView(frame: .zero)
    private let playBadge = UIImageView()
    private var textLeading: NSLayoutConstraint!
    private var withThumb: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        clipsToBounds = true
        accessibilityIgnoresInvertColors = true

        accentBar.layer.cornerRadius = 1.5
        accentBar.translatesAutoresizingMaskIntoConstraints = false

        textLabel.font = DesignSystem.Typography.handle()
        textLabel.adjustsFontForContentSizeCategory = true
        metricsLabel.font = DesignSystem.Typography.caption()
        metricsLabel.textColor = DesignSystem.Color.tertiaryLabel

        let texts = UIStackView(arrangedSubviews: [textLabel, metricsLabel])
        texts.axis = .vertical
        texts.spacing = 4
        texts.translatesAutoresizingMaskIntoConstraints = false

        thumb.setRounded(10)
        thumb.translatesAutoresizingMaskIntoConstraints = false
        playBadge.image = DesignSystem.icon("play.circle.fill", pointSize: 20)
        playBadge.tintColor = .white
        playBadge.translatesAutoresizingMaskIntoConstraints = false
        thumb.addSubview(playBadge)

        addSubview(accentBar)
        addSubview(texts)
        addSubview(thumb)
        textLeading = texts.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        let thumbTrailing = thumb.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        let textToThumb = texts.trailingAnchor.constraint(lessThanOrEqualTo: thumb.leadingAnchor, constant: -10)
        let textToEdge = texts.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        let thumbBottom = bottomAnchor.constraint(greaterThanOrEqualTo: thumb.bottomAnchor, constant: 8)
        withThumb = [textToThumb, thumbBottom, thumb.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                     thumbTrailing, thumb.widthAnchor.constraint(equalToConstant: Self.thumbSide),
                     thumb.heightAnchor.constraint(equalToConstant: Self.thumbSide)]
        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            accentBar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            accentBar.widthAnchor.constraint(equalToConstant: 3),
            textLeading,
            texts.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            bottomAnchor.constraint(greaterThanOrEqualTo: texts.bottomAnchor, constant: 10),
            textToEdge,
            playBadge.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
            playBadge.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
        ])
        NSLayoutConstraint.activate(withThumb)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `text` (or "Photo" / "Video" when the post is only media) in the
    /// given look. Returns false when there is nothing to show.
    @discardableResult
    func configure(text: String?, look: Look, tint: UIColor, likeCount: Int?, thumbURL: URL?, isVideo: Bool) -> Bool {
        let hasThumb = AppSettings.imagesEnabled && thumbURL != nil
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = trimmed.isEmpty && thumbURL != nil ? (isVideo ? "Video" : "Photo") : trimmed
        guard !body.isEmpty else { return false }

        switch look {
        case .quoted:
            backgroundColor = DesignSystem.Color.surface
            layer.cornerRadius = 12
            accentBar.isHidden = false
            accentBar.backgroundColor = tint
            textLeading.constant = 20
            textLabel.numberOfLines = 3
        case .bubble:
            backgroundColor = tint.withAlphaComponent(0.10)
            layer.cornerRadius = 16
            accentBar.isHidden = true
            textLeading.constant = 12
            textLabel.numberOfLines = 6
        }
        let color = look == .quoted ? DesignSystem.Color.secondaryLabel : DesignSystem.Color.label
        textLabel.attributedText = TwemojiText.attributed(body, font: DesignSystem.Typography.handle(), color: color)
        if trimmed.isEmpty { textLabel.textColor = DesignSystem.Color.tertiaryLabel }

        metricsLabel.attributedText = likeCount.flatMap { $0 > 0 && look == .quoted ? Self.metrics(likes: $0) : nil }
        metricsLabel.isHidden = metricsLabel.attributedText == nil

        thumb.isHidden = !hasThumb
        withThumb.forEach { $0.isActive = hasThumb }
        playBadge.isHidden = !isVideo
        if hasThumb {
            thumb.load(url: thumbURL, targetSize: CGSize(width: Self.thumbSide, height: Self.thumbSide))
        } else {
            thumb.cancel()
        }
        return true
    }

    func prepareForReuse() {
        thumb.cancel()
    }

    /// "♥ 1.2K", the heart in the like colour.
    private static func metrics(likes: Int) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = DesignSystem.icon("heart.fill", pointSize: 10)?
            .withTintColor(DesignSystem.Color.like, renderingMode: .alwaysOriginal)
        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(string: " " + Format.count(likes)))
        result.addAttributes([.font: DesignSystem.Typography.caption(), .foregroundColor: DesignSystem.Color.tertiaryLabel],
                             range: NSRange(location: 0, length: result.length))
        return result
    }
}
