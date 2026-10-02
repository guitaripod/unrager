import UIKit
import UnragerKit

/// The single source of visual truth. Colors are computed (so no non-Sendable
/// global state under strict concurrency); light/dark is handled by dynamic
/// `UIColor`s, never by branching at call sites.
enum DesignSystem {
    enum Color {
        /// X brand blue, brightened in dark mode and deepened in light mode so
        /// text and white-on-blue buttons clear 4.5:1 contrast.
        static var accent: UIColor {
            UIColor { trait in
                (trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.231, green: 0.671, blue: 0.961, alpha: 1)
                    : UIColor(red: 0.05, green: 0.47, blue: 0.80, alpha: 1)).forContrast(of: trait)
            }
        }
        static var background: UIColor { .systemBackground }
        static var elevatedBackground: UIColor { .secondarySystemBackground }
        static var surface: UIColor { .secondarySystemBackground }
        static var label: UIColor { .label }
        static var secondaryLabel: UIColor { .secondaryLabel }
        static var tertiaryLabel: UIColor { .tertiaryLabel }
        static var separator: UIColor { .separator }

        static var like: UIColor {
            UIColor { trait in
                (trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.976, green: 0.231, blue: 0.518, alpha: 1)
                    : UIColor(red: 0.85, green: 0.12, blue: 0.42, alpha: 1)).forContrast(of: trait)
            }
        }
        static var retweet: UIColor {
            UIColor { trait in
                (trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.0, green: 0.729, blue: 0.408, alpha: 1)
                    : UIColor(red: 0.0, green: 0.52, blue: 0.28, alpha: 1)).forContrast(of: trait)
            }
        }
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

    /// Each handle tint as packed light- and dark-mode RGB. Every light tint
    /// clears 4.5:1 on white and every dark one 4.5:1 on black, so a name or
    /// mention reads as body text does (checked by `HandlePaletteTests`).
    static let handlePaletteRGB: [(light: Int, dark: Int)] = [
        (0x1B6FB0, 0x4FB4FF),
        (0x0E7C8C, 0x3FD4E6),
        (0x0B7A4E, 0x36E0A0),
        (0x427A0A, 0x9BE055),
        (0x76690B, 0xE0D44F),
        (0x94650F, 0xFFC04F),
        (0xB0561B, 0xFF8A4F),
        (0xB01B3A, 0xFF6B8A),
        (0xA01B7A, 0xFF6BD4),
        (0x7A1BA0, 0xC06BFF),
        (0x4F35C0, 0x9B8AFF),
        (0x355AC0, 0x6B9BFF),
    ]

    @MainActor
    private static let handlePalette: [UIColor] = handlePaletteRGB.map { dynamic(light: $0.light, dark: $0.dark) }

    @MainActor
    private static func dynamic(light: Int, dark: Int) -> UIColor {
        UIColor { trait in
            UIColor(rgb: trait.userInterfaceStyle == .dark ? dark : light).forContrast(of: trait)
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
        /// The user's text-size multiplier, composed on top of the system's
        /// Dynamic Type scale (a user who bumps both gets both).
        static var scale: CGFloat { AppSettings.fontScale.multiplier }

        private static func scaled(_ style: UIFont.TextStyle, size: CGFloat, weight: UIFont.Weight) -> UIFont {
            UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size * scale, weight: weight))
        }

        /// A system font at `size`, scaled by the user's text-size choice (no
        /// Dynamic Type metric). Literal-size fonts route through here so nothing
        /// escapes the scale — the regression guard greps for stray
        /// `systemFont(ofSize:` outside this file.
        static func system(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
            .systemFont(ofSize: size * scale, weight: weight)
        }

        static func name() -> UIFont { scaled(.subheadline, size: 15, weight: .bold) }
        static func handle() -> UIFont { scaled(.subheadline, size: 15, weight: .regular) }
        static func body() -> UIFont {
            let base = UIFont.preferredFont(forTextStyle: .body)
            return base.withSize(base.pointSize * scale)
        }
        static func editor() -> UIFont { scaled(.title3, size: 20, weight: .regular) }
        static func metric() -> UIFont { scaled(.footnote, size: 13, weight: .regular) }
        /// The action bar's counts: `metric()`, but capped at 20 pt so five
        /// buttons and the views count still fit one row at the accessibility
        /// text sizes, where the counts matter less than reaching the buttons.
        static func actionMetric() -> UIFont {
            UIFontMetrics(forTextStyle: .footnote).scaledFont(
                for: .systemFont(ofSize: 13 * scale, weight: .regular), maximumPointSize: 20)
        }
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
    /// The colour as drawn under `trait`: unchanged normally, and with
    /// Increase Contrast on a step further from the background, darker in
    /// light mode and lighter in dark mode.
    func forContrast(of trait: UITraitCollection) -> UIColor {
        guard trait.accessibilityContrast == .high else { return self }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return self }
        if trait.userInterfaceStyle == .dark {
            let lift: CGFloat = 0.3
            return UIColor(red: red + (1 - red) * lift, green: green + (1 - green) * lift,
                           blue: blue + (1 - blue) * lift, alpha: alpha)
        }
        let deepen: CGFloat = 0.78
        return UIColor(red: red * deepen, green: green * deepen, blue: blue * deepen, alpha: alpha)
    }

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
