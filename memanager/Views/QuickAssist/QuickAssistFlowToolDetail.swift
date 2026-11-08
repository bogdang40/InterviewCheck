import SwiftUI

/// Expanded detail for a tool call: referenced files, arguments, output,
/// and the overflow snapshot, kept beside the triggering row.
struct QuickAssistFlowToolDetail: View {
    let step: QuickAssistToolTraceStep

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if !step.referencedFiles.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    FieldLabel(text: "Files read")
                    ForEach(step.referencedFiles) { reference in
                        Text(reference.lineSummary.map { "\(reference.path)  \($0)" } ?? reference.path)
                            .font(OverlayType.monoMicro)
                            .foregroundStyle(OverlayPalette.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
            if !step.rawArgumentsJSON.isEmpty, step.rawArgumentsJSON != "{}" {
                monoSection(title: "Arguments", body: step.rawArgumentsJSON)
            }
            if let content = step.resultContent, !content.isEmpty {
                monoSection(title: step.state == .failed ? "Error output" : "Output", body: content)
            }
            overflowSection
        }
    }

    @ViewBuilder
    private var overflowSection: some View {
        if step.contentTruncated, let overflowPath = step.overflowPath {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                FieldLabel(text: "Overflow snapshot")
                Link(overflowPath, destination: URL(fileURLWithPath: overflowPath))
                    .font(OverlayType.monoMicro)
            }
        } else if step.contentTruncated {
            ToneBadge(text: "Only a durable excerpt is shown", tone: .warning)
        }
    }

    private func monoSection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            FieldLabel(text: title)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(body)
                    .font(OverlayType.mono)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .textSelection(.enabled)
                    .padding(DesignTokens.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                    .fill(OverlayPalette.well)
            )
        }
    }
}
