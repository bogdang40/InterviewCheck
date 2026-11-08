import SwiftUI

/// The selected timeline event with its summary and detail, plus Open and
/// Branch here. Branching copies the thread up to this turn into a new
/// thread and selects it for the timeline.
struct SessionEventDetailCard: View {
    @ObservedObject private var controller = SessionController.shared
    let event: WorkstreamTimelineEvent
    @Binding var selectedThreadId: String?

    private var canBranch: Bool {
        event.type == .quickAssist && event.threadId != nil && event.turnId != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SurfaceHeader(event.title, subtitle: TimelineTimeFormatter.clock(event.timestamp), prominence: .heading) {
                ToneBadge(text: event.type.shortTitle, tone: event.severity.tone, style: .outline)
            }
            Text(event.summary)
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = event.detail, !detail.isEmpty {
                Text(detail)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button("Open") {
                    controller.openWorkstreamTimelineEvent(event)
                }
                .buttonStyle(.overlay(.primary, size: .small))
                if canBranch {
                    Button("Branch here", action: branch)
                        .buttonStyle(.overlay(.secondary, size: .small))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .toneEdgeCard(event.severity.tone)
    }

    private func branch() {
        guard let threadId = event.threadId, let turnId = event.turnId else { return }
        if let branched = controller.branchQuickAssistThread(fromThreadID: threadId, turnID: turnId) {
            selectedThreadId = branched
        }
    }
}
