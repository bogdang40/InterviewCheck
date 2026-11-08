import SwiftUI

/// Scaling strategies and the bottlenecks they answer. Malformed strategies
/// (blank or placeholder descriptions) are dropped rather than shown as
/// empty cards.
struct DesignScalabilityBlock: View {
    let scalability: ScalabilityBlock
    let fontSize: CGFloat

    private var validStrategies: [ScalabilityStrategy] {
        scalability.strategies.filter { DesignTextValidator.isMeaningful($0.description) }
    }

    private var hasContent: Bool {
        DesignTextValidator.isMeaningful(scalability.description)
            || !validStrategies.isEmpty
            || !scalability.bottlenecks.isEmpty
    }

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                DesignProseBlock(text: scalability.description, fontSize: fontSize)
                ForEach(validStrategies) { strategy in
                    DesignStrategyCard(strategy: strategy, fontSize: fontSize)
                }
                DesignBulletList(
                    title: "Bottlenecks",
                    systemImage: "exclamationmark.triangle",
                    items: scalability.bottlenecks,
                    fontSize: fontSize,
                    tone: .warning
                )
            }
        }
    }
}

private struct DesignStrategyCard: View {
    let strategy: ScalabilityStrategy
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(strategy.name)
                .font(OverlayType.bodyStrong(fontSize))
                .foregroundStyle(OverlayPalette.accent)
            SpeakableMarkdownView(
                text: strategy.description,
                fontSize: fontSize - 1,
                showChunkIndicators: false,
                chunkTrackingMode: .teleprompter
            )
            if let tradeOffs = strategy.tradeOffs, DesignTextValidator.isMeaningful(tradeOffs) {
                BadgeLabelledRow(label: "Trade off", value: tradeOffs, tone: .warning, fontSize: fontSize - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlayCard(.raised, cornerRadius: DesignTokens.Radius.md, padding: DesignTokens.Spacing.md)
    }
}
