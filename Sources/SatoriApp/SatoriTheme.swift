import AppKit
import SwiftUI

/// Design tokens for Satori. One source of truth for color, spacing, radius,
/// elevation and motion.
///
/// Color philosophy — "quiet paper, one ink": surfaces and chrome stay neutral
/// (system grays that adapt to light/dark automatically), and the accent is
/// spent sparingly on the few things that genuinely deserve attention —
/// selection, the primary action, active state, and links. Chrome (icons,
/// section labels, hairlines, progress on secondary surfaces) is intentionally
/// NOT accent-colored; that restraint is what keeps the app calm.
enum SatoriTheme {
    // MARK: Accent

    /// Primary accent: a crisp ink-violet. Adaptive so it stays a deep, legible
    /// ink on light backgrounds and brightens on dark ones instead of dying.
    static let accent = Color(nsColor: NSColor(name: "SatoriAccent") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.68, green: 0.63, blue: 0.98, alpha: 1)
            : NSColor(srgbRed: 0.35, green: 0.29, blue: 0.72, alpha: 1)
    })

    /// A faint accent wash for selected rows and active chips. Kept very light
    /// so a selected surface reads as "tinted paper", not a saturated block.
    static let accentWash = Color(nsColor: NSColor(name: "SatoriAccentWash") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.68, green: 0.63, blue: 0.98, alpha: 0.18)
            : NSColor(srgbRed: 0.35, green: 0.29, blue: 0.72, alpha: 0.10)
    })

    // MARK: Neutral chrome

    /// Hairline separators and card borders. A whisper, never a line that
    /// competes with content.
    static let hairline = Color.primary.opacity(0.08)

    /// Default icon tint for chrome (sidebar, menus, toolbar). Neutral on
    /// purpose — icons are wayfinding, not decoration.
    static let iconChrome = Color.secondary

    // MARK: Spacing (4pt base)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Corner radius

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
    }

    // MARK: Motion

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.18)
        static let standard = Animation.spring(response: 0.34, dampingFraction: 0.86)
        static let gentle = Animation.easeInOut(duration: 0.28)
    }
}

private extension NSAppearance {
    var isDarkMode: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - Reusable surface modifiers

extension View {
    /// A raised content card: neutral fill, hairline border, gentle shadow.
    /// `emphasized` lifts it slightly (streaming answer) using the accent only
    /// as a thin edge, never a fill.
    func satoriCard(
        radius: CGFloat = SatoriTheme.Radius.md,
        padding: CGFloat = SatoriTheme.Spacing.md,
        emphasized: Bool = false
    ) -> some View {
        self
            .padding(padding)
            .background(.background, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        emphasized ? SatoriTheme.accent.opacity(0.30) : SatoriTheme.hairline,
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(emphasized ? 0.08 : 0.04), radius: emphasized ? 10 : 5, y: 1)
    }

    /// A recessed / secondary surface for context blocks and inline chips.
    func satoriInset(radius: CGFloat = SatoriTheme.Radius.sm) -> some View {
        self.background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
