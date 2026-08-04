import AppKit
import SwiftUI

/// Design tokens for Satori. One source of truth for color, spacing, radius,
/// elevation, motion and type.
///
/// Color philosophy is drawn from the app's own icon — an ivory rounded square
/// with pale lavender and one warm-gold spark rising from an open book:
///   • paper      — warm ivory reading surface (the "page" you read on)
///   • accent     — lavender; interaction (selection, primary action, focus)
///   • gold       — the spark of understanding; used ONLY for the moment an
///                  answer is being formed / appears, never for chrome
/// So every color has one job. Chrome (icons, hairlines, labels) stays neutral.
///
/// Type roles echo the same idea: the reading surface speaks in serif (you are
/// reading), the chrome speaks in the system sans, code stays monospaced.
enum SatoriTheme {
    // MARK: Adaptive colors

    /// Warm ivory paper for the reading / learning surface. The "book".
    static let paper = Color(nsColor: NSColor(name: "SatoriPaper") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.098, green: 0.092, blue: 0.118, alpha: 1)   // #191821 warm dark
            : NSColor(srgbRed: 0.965, green: 0.949, blue: 0.918, alpha: 1)   // #F6F2EA warm ivory
    })

    /// A raised paper surface (fields, hover chips, the live answer).
    static let paperRaised = Color(nsColor: NSColor(name: "SatoriPaperRaised") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.145, green: 0.135, blue: 0.165, alpha: 1)
            : NSColor(white: 1.0, alpha: 1)
    })

    /// Lavender — interaction. A calm ink-violet on light, brighter on dark.
    static let accent = Color(nsColor: NSColor(name: "SatoriAccent") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.68, green: 0.63, blue: 0.98, alpha: 1)
            : NSColor(srgbRed: 0.42, green: 0.35, blue: 0.74, alpha: 1)
    })

    /// A faint lavender wash for selected rows / active chips.
    static let accentWash = Color(nsColor: NSColor(name: "SatoriAccentWash") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.68, green: 0.63, blue: 0.98, alpha: 0.18)
            : NSColor(srgbRed: 0.42, green: 0.35, blue: 0.74, alpha: 0.10)
    })

    /// Warm gold — the spark of understanding. Answer moment only.
    static let gold = Color(nsColor: NSColor(name: "SatoriGold") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.90, green: 0.68, blue: 0.32, alpha: 1)
            : NSColor(srgbRed: 0.71, green: 0.46, blue: 0.16, alpha: 1)
    })

    static let goldWash = Color(nsColor: NSColor(name: "SatoriGoldWash") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.90, green: 0.68, blue: 0.32, alpha: 0.16)
            : NSColor(srgbRed: 0.71, green: 0.46, blue: 0.16, alpha: 0.10)
    })

    // MARK: Neutral chrome

    /// Hairline separators and borders. A whisper, never a competing line.
    static let hairline = Color.primary.opacity(0.08)

    /// Default tint for chrome icons.
    static let iconChrome = Color.secondary

    // MARK: Type

    // The reading surface uses system sans throughout; the identity's warmth
    // is carried by color and space, not a display face. Kept minimal so the
    // UI never fights the reader's own font settings.

    // MARK: Spacing (4pt base)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Corner radius — rounded-square family, matching the icon

    enum Radius {
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let lg: CGFloat = 18
        static let xl: CGFloat = 24
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

// MARK: - AppKit-facing colors

/// The same tokens exposed as `NSColor`s for AppKit views (the PDF selection
/// toolbar). `dynamicProvider` makes them track light/dark automatically, so
/// a platform-agnostic view stays consistent with the SwiftUI theme.
enum SatoriThemeAppKit {
    static let accent = NSColor(name: "SatoriAccent") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.68, green: 0.63, blue: 0.98, alpha: 1)
            : NSColor(srgbRed: 0.42, green: 0.35, blue: 0.74, alpha: 1)
    }
    /// White text on the accent button — picked for contrast on both modes.
    static let onAccent = NSColor.white
    /// The raised paper surface the toolbar sits on (warm ivory in light mode,
    /// warm dark in dark mode), so it reads as a distinct surface over the PDF.
    static let paperRaised = NSColor(name: "SatoriPaperRaised") { appearance in
        appearance.isDarkMode
            ? NSColor(srgbRed: 0.145, green: 0.135, blue: 0.165, alpha: 1)
            : NSColor(srgbRed: 0.988, green: 0.980, blue: 0.960, alpha: 1)
    }
}

// MARK: - Reusable surface modifiers

extension View {
    /// A raised paper surface. `emphasized` marks the live "understanding"
    /// moment with a warm-gold hairline — the spark — instead of lavender.
    func satoriPaper(
        radius: CGFloat = SatoriTheme.Radius.md,
        padding: CGFloat = SatoriTheme.Spacing.md,
        emphasized: Bool = false
    ) -> some View {
        self
            .padding(padding)
            .background(SatoriTheme.paperRaised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        emphasized ? SatoriTheme.gold.opacity(0.45) : SatoriTheme.hairline,
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(emphasized ? 0.10 : 0.04), radius: emphasized ? 12 : 5, y: emphasized ? 3 : 1)
    }

    /// A recessed surface for context blocks and inline chips.
    func satoriInset(radius: CGFloat = SatoriTheme.Radius.sm) -> some View {
        self.background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
