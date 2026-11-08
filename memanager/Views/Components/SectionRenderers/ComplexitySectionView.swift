import SwiftUI

/// Evaluate: time and space as two metric tiles, then the trade off that
/// was chosen, so the closing statement is three things read in order.
struct ComplexitySectionView: View {
    let content: ComplexityContent
    @ObservedObject private var settings = SettingsManager.shared

    /// The parser leaves the prompt's own bold label shape alone, so the
    /// renderer recovers the figures from the raw text before giving up.
    private var resolved: ComplexityContent {
        ComplexityFallbackResolver.resolve(content)
    }

    var body: some View {
        let resolved = resolved
        if resolved.isEmpty {
            MarkdownRenderer(text: resolved.rawContent, fontSize: settings.fontSize)
        } else {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    if let time = resolved.time {
                        ComplexityMetricCard(analysis: time)
                    }
                    if let space = resolved.space {
                        ComplexityMetricCard(analysis: space)
                    }
                }

                if let tradeOff = resolved.tradeOff?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !tradeOff.isEmpty {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        FieldLabel(text: "Trade off")
                        TradeOffCard(content: tradeOff, fontSize: settings.fontSize)
                    }
                }
            }
        }
    }
}
