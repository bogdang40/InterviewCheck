import SwiftUI

/// The request path as prose plus the numbered hops the parser found.
struct DesignDataFlowBlock: View {
    let dataFlow: DataFlowBlock
    let fontSize: CGFloat

    private var hasContent: Bool {
        DesignTextValidator.isMeaningful(dataFlow.description) || !dataFlow.flows.isEmpty
    }

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                DesignProseBlock(text: dataFlow.description, fontSize: fontSize)
                if !dataFlow.flows.isEmpty {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        ForEach(dataFlow.flows) { flow in
                            DesignFlowRow(flow: flow, fontSize: fontSize)
                        }
                    }
                }
            }
        }
    }
}

private struct DesignFlowRow: View {
    let flow: DataFlowStep
    let fontSize: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Text("\(flow.number)")
                .font(OverlayType.monoMicro)
                .foregroundStyle(OverlayPalette.accent)
                .frame(width: 18, alignment: .trailing)
                .padding(.top, DesignTokens.Spacing.xxs)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(flow.from)
                        .font(OverlayType.bodyStrong(fontSize))
                    Image(systemName: "arrow.right")
                        .font(OverlayType.micro)
                        .foregroundStyle(OverlayPalette.textTertiary)
                    Text(flow.to)
                        .font(OverlayType.bodyStrong(fontSize))
                }
                .foregroundStyle(OverlayPalette.textPrimary)

                if DesignTextValidator.isMeaningful(flow.description) {
                    Text(flow.description)
                        .font(OverlayType.body(fontSize - 1))
                        .foregroundStyle(OverlayPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
