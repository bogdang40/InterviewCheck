import SwiftUI

/// Compact inline representation of a tool call inside the reasoning flow:
/// status, tool name, condensed input, duration. The chevron expands a
/// detail panel so heavy outputs never leak into the train of thought.
struct QuickAssistFlowToolRow: View {
    let step: QuickAssistToolTraceStep
    let isExpanded: Bool
    let onToggleExpanded: () -> Void

    private var tone: OverlayTone? {
        switch step.state {
        case .running: return .info
        case .completed: return nil
        case .failed: return .critical
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                QuickAssistFlowToolDetail(step: step)
                    .padding(.top, DesignTokens.Spacing.sm)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .overlayCard(.base, cornerRadius: DesignTokens.Radius.md, stroke: tone?.stroke)
    }

    private var header: some View {
        Button(action: onToggleExpanded) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
                QuickAssistFlowToolStatusIcon(state: step.state)
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.toolName)
                        .font(OverlayType.mono)
                        .foregroundStyle(OverlayPalette.textPrimary)
                    if !step.displayInput.isEmpty {
                        Text(step.displayInput)
                            .font(OverlayType.monoMicro)
                            .foregroundStyle(OverlayPalette.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: DesignTokens.Spacing.xs)
                durationLabel
                Image(systemName: "chevron.right")
                    .font(OverlayType.monoMicro)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(DesignTokens.Motion.focus, value: isExpanded)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var durationLabel: some View {
        if let durationMs = step.durationMs {
            Text(Self.formatDuration(durationMs))
                .font(OverlayType.monoMicro)
                .foregroundStyle(OverlayPalette.textTertiary)
        } else if step.state == .running {
            ToneBadge(text: "running", tone: .info)
        }
    }

    static func formatDuration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.2fs", Double(ms) / 1000.0)
    }
}
