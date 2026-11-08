import SwiftUI

/// The overlay's type scale. Seven roles cover every screen; views pick a
/// role instead of a point size so the hierarchy stays identical across
/// surfaces. The response body is the only role that follows the user's
/// font size setting.
enum OverlayType {

    /// The one line the user reads at a glance: say first, empty state title.
    static let display = Font.system(size: 20, weight: .semibold)

    /// Surface and card titles.
    static let title = Font.system(size: 15, weight: .semibold)

    /// Section headings inside a card.
    static let heading = Font.system(size: 13, weight: .semibold)

    /// Default reading text.
    static let body = Font.system(size: 13)

    /// Reading text scaled by the font size setting.
    static func body(_ size: CGFloat) -> Font {
        .system(size: size)
    }

    /// Emphasised reading text scaled by the font size setting.
    static func bodyStrong(_ size: CGFloat) -> Font {
        .system(size: size, weight: .medium)
    }

    /// Buttons, chips, row labels.
    static let callout = Font.system(size: 12, weight: .medium)

    /// Metadata and hints.
    static let caption = Font.system(size: 11)
    static let captionStrong = Font.system(size: 11, weight: .semibold)

    /// Badges and counters.
    static let micro = Font.system(size: 10, weight: .semibold)

    /// Code, key caps, identifiers.
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoMicro = Font.system(size: 10, weight: .semibold, design: .monospaced)

    /// Fenced code blocks.
    static let code = Font.system(size: 12.5, design: .monospaced)

    /// The figure in a metric tile.
    static let metricValue = Font.system(size: 15, weight: .semibold, design: .monospaced)

    /// SF Symbols sized as layout elements rather than text. Symbols track
    /// the control they sit in, so the size is passed by the caller.
    static func symbol(_ size: CGFloat = 11, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }
}
