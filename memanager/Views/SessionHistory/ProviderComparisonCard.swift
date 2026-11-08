import SwiftUI

/// Per session provider comparison: a success bar and a latency bar for
/// each provider that answered a Quick Assist turn.
struct ProviderComparisonCard: View {
    let providers: [ProviderSessionSummary]

    private var scale: ProviderComparisonScale {
        ProviderComparisonScale(providers: providers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SurfaceHeader("Provider comparison", systemImage: "cpu", count: providers.isEmpty ? nil : providers.count, prominence: .heading)
            if providers.isEmpty {
                Text("No provider data for this session.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
            } else {
                ForEach(providers) { provider in
                    row(provider)
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
        .overlayCard(.base)
    }

    private func row(_ provider: ProviderSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(provider.provider)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                if let model = provider.model, !model.isEmpty {
                    Text(model)
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("\(provider.callCount) calls")
                    .font(OverlayType.monoMicro)
                    .foregroundStyle(OverlayPalette.textTertiary)
            }
            bar(label: "Success", value: String(format: "%.0f%%", provider.successRate), fraction: scale.successFraction(provider), tone: .success)
            bar(label: "Latency", value: provider.averageLatencyMs.map { "\($0)ms" } ?? "n/a", fraction: scale.latencyFraction(provider), tone: .warning)
        }
        .padding(DesignTokens.Spacing.sm)
        .overlayCard(.raised, cornerRadius: DesignTokens.Radius.md)
    }

    private func bar(label: String, value: String, fraction: Double, tone: OverlayTone) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(label)
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textTertiary)
                .frame(width: 52, alignment: .leading)
            ProgressTrack(progress: fraction, tone: tone)
            Text(value)
                .font(OverlayType.monoMicro)
                .foregroundStyle(OverlayPalette.textSecondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
