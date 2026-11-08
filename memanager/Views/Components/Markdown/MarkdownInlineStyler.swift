import SwiftUI

/// Applies the overlay's inline treatments to a parsed markdown string:
/// inline code in the mono face on an overlay veil, and links in the
/// accent. Block level structure is left to `MarkdownBlockResolver`.
enum MarkdownInlineStyler {
    static func styled(_ source: AttributedString) -> AttributedString {
        var result = source
        for run in source.runs {
            if isInlineCode(run) {
                result[run.range].swiftUI.font = OverlayType.mono
                result[run.range].swiftUI.backgroundColor = OverlayPalette.surfaceOverlay
            }
            if run.link != nil {
                result[run.range].swiftUI.foregroundColor = OverlayPalette.accent
                result[run.range].swiftUI.underlineStyle = Text.LineStyle.single
            }
        }
        return result
    }

    static func isInlineCode(_ run: AttributedString.Runs.Run) -> Bool {
        run.inlinePresentationIntent?.contains(.code) == true
    }
}
