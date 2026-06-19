import AppKit

/// The single source of visual truth, mirroring the iOS `DesignSystem`. Colors
/// are computed dynamic `NSColor`s so light/dark resolves through the effective
/// appearance, never by branching at call sites.
enum DesignSystem {
    enum Color {
        /// X brand blue, slightly brightened in dark mode.
        static var accent: NSColor {
            NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor(red: 0.231, green: 0.671, blue: 0.961, alpha: 1)
                    : NSColor(red: 0.114, green: 0.608, blue: 0.941, alpha: 1)
            }
        }
        static var background: NSColor { .textBackgroundColor }
        static var windowBackground: NSColor { .windowBackgroundColor }
        static var elevatedBackground: NSColor { .underPageBackgroundColor }
        static var surface: NSColor {
            NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor(white: 1, alpha: 0.06)
                    : NSColor(white: 0, alpha: 0.04)
            }
        }
        static var label: NSColor { .labelColor }
        static var secondaryLabel: NSColor { .secondaryLabelColor }
        static var tertiaryLabel: NSColor { .tertiaryLabelColor }
        static var separator: NSColor { .separatorColor }

        static var like: NSColor { NSColor(red: 0.976, green: 0.231, blue: 0.518, alpha: 1) }
        static var retweet: NSColor { NSColor(red: 0.0, green: 0.729, blue: 0.408, alpha: 1) }
        static var quote: NSColor { NSColor(red: 0.471, green: 0.353, blue: 0.961, alpha: 1) }
        static var verified: NSColor { accent }
        static var live: NSColor { .systemRed }
        /// Hashtags in body text. The X-native accent blue.
        static var hashtag: NSColor { accent }
        /// Inline t.co links in body text. The X-native accent blue.
        static var link: NSColor { accent }
    }

    /// Deterministic per-handle tint, mirroring the TUI's `handle_color` (an
    /// FNV-1a hash modulo a fixed palette) so a body `@mention` always matches
    /// that author's header color. The palette is tuned for legibility in both
    /// light and dark mode rather than the TUI's raw 256-color cube.
    static func handleColor(_ handle: String) -> NSColor {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in handle.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return handlePalette[Int(hash % UInt64(handlePalette.count))]
    }

    private static let handlePalette: [NSColor] = [
        dynamic(light: (0.0, 0.47, 0.84), dark: (0.36, 0.71, 1.0)),
        dynamic(light: (0.0, 0.55, 0.62), dark: (0.20, 0.82, 0.84)),
        dynamic(light: (0.0, 0.56, 0.39), dark: (0.22, 0.84, 0.55)),
        dynamic(light: (0.36, 0.55, 0.10), dark: (0.62, 0.82, 0.30)),
        dynamic(light: (0.62, 0.51, 0.0), dark: (0.92, 0.78, 0.30)),
        dynamic(light: (0.78, 0.45, 0.0), dark: (0.98, 0.69, 0.31)),
        dynamic(light: (0.82, 0.31, 0.20), dark: (0.98, 0.52, 0.44)),
        dynamic(light: (0.80, 0.18, 0.42), dark: (0.98, 0.45, 0.68)),
        dynamic(light: (0.62, 0.27, 0.78), dark: (0.84, 0.56, 0.98)),
        dynamic(light: (0.42, 0.36, 0.86), dark: (0.66, 0.62, 1.0)),
        dynamic(light: (0.27, 0.45, 0.86), dark: (0.55, 0.69, 1.0)),
        dynamic(light: (0.0, 0.50, 0.71), dark: (0.36, 0.78, 0.94)),
    ]

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat),
                                dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.isDark ? dark : light
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
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
        static func name() -> NSFont { .systemFont(ofSize: 14, weight: .bold) }
        static func handle() -> NSFont { .systemFont(ofSize: 14, weight: .regular) }
        static func body() -> NSFont { .systemFont(ofSize: 14, weight: .regular) }
        static func metric() -> NSFont { .systemFont(ofSize: 12, weight: .regular) }
        static func caption() -> NSFont { .systemFont(ofSize: 11, weight: .regular) }
        static func title() -> NSFont { .systemFont(ofSize: 22, weight: .heavy) }
    }

    static func icon(_ systemName: String, pointSize: CGFloat = 16, weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight.symbolWeight)
        return NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

private extension NSFont.Weight {
    var symbolWeight: NSFont.Weight { self }
}
