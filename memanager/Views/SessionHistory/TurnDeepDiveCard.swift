import SwiftUI

/// Inspector for one Quick Assist turn: the question and answer, then
/// verification, routing, latency, and feedback rows. The record loads off
/// the main thread when the card appears.
struct TurnDeepDiveCard: View {
    let event: WorkstreamTimelineEvent

    @State private var record: QuickAssistCallRecord?
    @State private var isLoading = false
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SurfaceHeader("Turn deep dive", systemImage: "magnifyingglass", prominence: .heading) {
                if let record {
                    ToneBadge(text: record.modelTier.badgeLabel, tone: record.modelTier.badgeTone, style: .outline)
                        .help(record.modelTier.helpText)
                }
            }
            if let record {
                exchange(record)
                TurnDeepDiveRows(record: record)
            } else if isLoading {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading turn")
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textTertiary)
                }
            } else {
                ToneBanner(tone: .warning, title: "Turn unavailable", message: "No saved turn record was found for this event.", actions: [BannerAction(title: "Retry", action: loadRecord)])
            }
        }
        .padding(DesignTokens.Spacing.md)
        .overlayCard(.base)
        .onAppear(perform: loadRecord)
        .onChange(of: event.id) { _, _ in loadRecord() }
    }

    @ViewBuilder
    private func exchange(_ record: QuickAssistCallRecord) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            if let question = record.question, !question.isEmpty {
                Text(question)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let response = record.responseText, !response.isEmpty {
                Text(response)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.sm)
        .overlayCard(.raised, cornerRadius: DesignTokens.Radius.md)
    }

    private func loadRecord() {
        record = nil
        let token = UUID()
        requestID = token
        isLoading = false
        guard let threadId = event.threadId else { return }
        isLoading = true
        let turnId = event.turnId ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            let match = SessionLogger.shared.getQuickAssistCall(threadId: threadId, turnId: turnId)
            DispatchQueue.main.async {
                guard token == requestID else { return }
                record = match
                isLoading = false
            }
        }
    }
}
