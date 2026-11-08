import SwiftUI

/// The decisions the design made and what each one gave up. Malformed
/// entries (blank or placeholder decisions) are dropped.
struct DesignTradeOffsBlock: View {
    let tradeOffs: [TradeOff]
    let fontSize: CGFloat

    private var validTradeOffs: [TradeOff] {
        tradeOffs.filter { DesignTextValidator.isMeaningful($0.decision) }
    }

    var body: some View {
        if !validTradeOffs.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                ForEach(validTradeOffs) { tradeOff in
                    DesignTradeOffCard(tradeOff: tradeOff, fontSize: fontSize)
                }
            }
        }
    }
}

private struct DesignTradeOffCard: View {
    let tradeOff: TradeOff
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                ToneBadge(text: "Chose", tone: .success)
                Text(tradeOff.decision)
                    .font(OverlayType.bodyStrong(fontSize))
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if DesignTextValidator.isMeaningful(tradeOff.alternative) {
                    Text("over")
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textTertiary)
                    Text(tradeOff.alternative)
                        .font(OverlayType.body(fontSize))
                        .foregroundStyle(OverlayPalette.textTertiary)
                        .strikethrough()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if DesignTextValidator.isMeaningful(tradeOff.reasoning) {
                SpeakableMarkdownView(
                    text: tradeOff.reasoning,
                    fontSize: fontSize - 1,
                    showChunkIndicators: false,
                    chunkTrackingMode: .teleprompter
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlayCard(.raised, cornerRadius: DesignTokens.Radius.md, padding: DesignTokens.Spacing.md)
    }
}
