import UIKit

/// The single source of visual truth. Colors are computed (so no non-Sendable
/// global state under strict concurrency); light/dark is handled by dynamic
/// `UIColor`s, never by branching at call sites.
enum DesignSystem {
    enum Color {
        /// X brand blue, slightly brightened in dark mode.
        static var accent: UIColor {
            UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.231, green: 0.671, blue: 0.961, alpha: 1)
                    : UIColor(red: 0.114, green: 0.608, blue: 0.941, alpha: 1)
            }
        }
        static var background: UIColor { .systemBackground }
        static var elevatedBackground: UIColor { .secondarySystemBackground }
        static var surface: UIColor { .secondarySystemBackground }
        static var label: UIColor { .label }
        static var secondaryLabel: UIColor { .secondaryLabel }
        static var tertiaryLabel: UIColor { .tertiaryLabel }
        static var separator: UIColor { .separator }

        static var like: UIColor { UIColor(red: 0.976, green: 0.231, blue: 0.518, alpha: 1) }
        static var retweet: UIColor { UIColor(red: 0.0, green: 0.729, blue: 0.408, alpha: 1) }
        static var quote: UIColor { UIColor(red: 0.471, green: 0.353, blue: 0.961, alpha: 1) }
        static var verified: UIColor { accent }
        static var live: UIColor { .systemRed }
        /// In-body hashtag tint — matches the accent so `#tag` reads as a link.
        static var hashtag: UIColor { accent }
    }

    /// Deterministic per-handle tint, ported from the TUI's `theme::handle_color`
    /// (FNV-1a over the lowercased handle, indexed into a fixed palette). The same
    /// handle always gets the same color so an in-body `@mention` matches that
    /// author's header tint. The palette is a spectral sweep that stays legible
    /// on both light and dark backgrounds.
    @MainActor
    static func handleColor(_ handle: String) -> UIColor {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in handle.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return handlePalette[Int(hash % UInt64(handlePalette.count))]
    }

    @MainActor
    private static let handlePalette: [UIColor] = [
        dynamic(light: 0x1B6FB0, dark: 0x4FB4FF),
        dynamic(light: 0x0E7C8C, dark: 0x3FD4E6),
        dynamic(light: 0x0E8C5A, dark: 0x36E0A0),
        dynamic(light: 0x4F8C0E, dark: 0x9BE055),
        dynamic(light: 0x8C7C0E, dark: 0xE0D44F),
        dynamic(light: 0xB07A1B, dark: 0xFFC04F),
        dynamic(light: 0xB0561B, dark: 0xFF8A4F),
        dynamic(light: 0xB01B3A, dark: 0xFF6B8A),
        dynamic(light: 0xA01B7A, dark: 0xFF6BD4),
        dynamic(light: 0x7A1BA0, dark: 0xC06BFF),
        dynamic(light: 0x4F35C0, dark: 0x9B8AFF),
        dynamic(light: 0x355AC0, dark: 0x6B9BFF),
    ]

    @MainActor
    private static func dynamic(light: Int, dark: Int) -> UIColor {
        UIColor { trait in
            UIColor(rgb: trait.userInterfaceStyle == .dark ? dark : light)
        }
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 16
        static let media: CGFloat = 14
        static let control: CGFloat = 12
        static let avatar: CGFloat = 22
        static let pill: CGFloat = 999
    }

    enum Typography {
        private static func scaled(_ style: UIFont.TextStyle, size: CGFloat, weight: UIFont.Weight) -> UIFont {
            UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
        }
        static func name() -> UIFont { scaled(.subheadline, size: 15, weight: .bold) }
        static func handle() -> UIFont { scaled(.subheadline, size: 15, weight: .regular) }
        static func body() -> UIFont { .preferredFont(forTextStyle: .body) }
        static func metric() -> UIFont { scaled(.footnote, size: 13, weight: .regular) }
        static func caption() -> UIFont { scaled(.caption1, size: 12, weight: .regular) }
        static func title() -> UIFont { scaled(.title2, size: 22, weight: .heavy) }
    }

    @MainActor
    static func icon(_ systemName: String, pointSize: CGFloat = 16, weight: UIFont.Weight = .regular) -> UIImage? {
        UIImage(systemName: systemName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .init(weight)))
    }
}

extension UIColor {
    /// Builds an opaque color from a packed `0xRRGGBB` integer.
    convenience init(rgb: Int) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }
}

private extension UIImage.SymbolWeight {
    init(_ weight: UIFont.Weight) {
        switch weight {
        case .bold: self = .bold
        case .semibold: self = .semibold
        case .medium: self = .medium
        case .heavy: self = .heavy
        case .light: self = .light
        default: self = .regular
        }
    }
}
