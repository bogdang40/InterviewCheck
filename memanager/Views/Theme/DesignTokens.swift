import SwiftUI
import AppKit

/// Single source of truth for the overlay's visual rhythm: spacing,
/// corner radii, opacity, motion primitives, and typography. Values here
/// are extracted from the existing surfaces (QuickAssistChrome,
/// QuickAssistResponseCanvas, MentorView) so migration is one-for-one
/// substitution, not reskin.
///
/// Motion primitives are gated on the system "reduce motion" preference:
/// `Motion.emptyStatePulse` collapses to a zero-duration linear curve when
/// `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true.
enum DesignTokens {

    // MARK: - Spacing

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 18
        static let xxl: CGFloat = 24
    }

    // MARK: - Radius

    enum Radius {
        static let pill: CGFloat = 999
        static let xs: CGFloat = 4
        static let sm: CGFloat = 9
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
    }

    // MARK: - Opacity

    enum Opacity {
        enum Surface {
            static let card: Double = 0.82
            static let cardEmphasis: Double = 0.96
        }
        enum Stroke {
            static let subtle: Double = 0.16
            static let `default`: Double = 0.24
            static let emphasis: Double = 0.28
        }
        enum Text {
            /// Full-opacity body text. Rely on the overlay background for
            /// contrast instead of dimming the text, which washes out on
            /// low-opacity overlay settings.
            static let body: Double = 1.0
            static let cursor: Double = 0.65
            static let caption: Double = 0.72
        }
    }

    // MARK: - Motion

    enum Motion {
        /// Input focus rings and subtle state changes. 120ms ease-out.
        static var focus: Animation {
            reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.12)
        }

        /// Top-level overlay content swaps (Quick Assist <-> Transcript
        /// <-> SystemDesignLiveGenerationView). 120ms ease-in-out.
        static var surfaceSwap: Animation {
            reduceMotion ? .linear(duration: 0) : .easeInOut(duration: 0.12)
        }

        /// Quick Assist turn navigation. 180ms ease-out.
        static var turnSwap: Animation {
            reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.18)
        }

        /// Inline disclosure / collapse (step cards, chunk views). 200ms.
        static var sectionExpand: Animation {
            reduceMotion ? .linear(duration: 0) : .easeInOut(duration: 0.20)
        }

        /// Larger collapsible panels (signals, experiments). 250ms ease-out.
        static var panelDisclosure: Animation {
            reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.25)
        }

        /// Ambient "alive, waiting" pulse for the empty-state affordance.
        /// 2.4s auto-reversing ease. Collapses to a no-op under reduce-motion.
        static var emptyStatePulse: Animation {
            reduceMotion
                ? .linear(duration: 0)
                : .easeInOut(duration: 2.4).repeatForever(autoreverses: true)
        }

        private static var reduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    // MARK: - Typography

    enum Typography {
        /// Streaming response body. The font size is read from settings at
        /// the call site; this helper returns the base face that will then
        /// be sized by the consumer.
        static func responseBody(size: CGFloat) -> Font {
            .system(size: size)
        }

        /// Caption rows (keyboard hints, metadata).
        static let responseCaption: Font = .caption

        /// Fenced and inline code. Matches CodeBlockView's in-flight font.
        static let codeBlock: Font = .system(size: 12.5, design: .monospaced)
    }

    // MARK: - Stroke helpers

    /// Common stroke configuration for overlay surfaces: ephemeral strokes
    /// that share the same color but differ only in opacity. Use this to
    /// avoid re-declaring `Color.white.opacity(0.24)` at every call site.
    static func subtleStroke(color: Color = OverlayPalette.hairlineStrong) -> Color {
        color.opacity(Opacity.Stroke.subtle)
    }

    static func defaultStroke(color: Color = OverlayPalette.hairlineStrong) -> Color {
        color.opacity(Opacity.Stroke.default)
    }

    static func emphasisStroke(color: Color = OverlayPalette.hairlineStrong) -> Color {
        color.opacity(Opacity.Stroke.emphasis)
    }
}
