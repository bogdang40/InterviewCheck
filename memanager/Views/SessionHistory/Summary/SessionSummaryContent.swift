import SwiftUI

/// Renders a summary by status: action items, background, follow up draft,
/// a fallback note, and the resume bar; or the generating and failed
/// states with the same resume bar.
struct SessionSummaryContent: View {
    let sessionID: String
    let summary: SessionSummary?
    let isRegenerating: Bool
    let onGenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if let summary {
                statusBody(summary)
            } else {
                ToneBanner(
                    tone: .neutral,
                    message: "No summary yet for this session.",
                    systemImage: "sparkles",
                    actions: [BannerAction(title: "Generate summary", kind: .secondary, action: onGenerate)]
                )
                .disabled(isRegenerating)
            }
            ResumeSessionBar(sessionID: sessionID)
        }
    }

    @ViewBuilder
    private func statusBody(_ summary: SessionSummary) -> some View {
        switch summary.status {
        case .completed, .heuristic:
            ActionItemsList(items: summary.actionItems)
            BackgroundSummaryCard(text: summary.backgroundSummary)
            if let draft = summary.followUpEmailDraft, !draft.isEmpty {
                FollowUpDraftCard(text: draft)
            }
            if summary.status == .heuristic {
                ToneBanner(tone: .warning, message: "Heuristic fallback: the model summary was unavailable.")
            }
        case .pending, .generating:
            HStack(spacing: DesignTokens.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Generating summary")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
            }
        case .failed:
            ToneBanner(
                tone: .critical,
                message: summary.errorMessage ?? "Summary failed to generate.",
                actions: [BannerAction(title: "Try again", action: onGenerate)]
            )
        }
    }
}
