import SwiftUI

/// Read only request evidence. Future request controls have a separate route.
struct QuickAssistSourcesView: View {
    let presentation: QuickAssistSourcePresentation
    let onOpenContext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text("Sources for this answer").font(OverlayType.title)
            switch presentation {
            case .saved(let snapshot):
                savedSources(snapshot)
            case .unavailable(let reason):
                Text(reason.message)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Hairline()
            Button("Context for the next question", action: onOpenContext)
                .buttonStyle(.overlay(.secondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func savedSources(_ snapshot: QuickAssistSourceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text("Saved request time: \(snapshot.requestedAt.formatted(date: .abbreviated, time: .standard)).")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
            recordedText("Saved question", value: snapshot.question,
                         note: snapshot.questionSource == .auto ? "Automatic question, resolved after generation." : nil)
            recordedText("Recorded transcript", value: snapshot.transcript)
            recordedText("Recorded extra context", value: snapshot.extraContext)
            if snapshot.hasPreviousResponse || snapshot.previousResponse != nil {
                DisclosureGroup("Prior answer context") {
                    recordedText("Recorded prior answer", value: snapshot.previousResponse)
                        .padding(.top, DesignTokens.Spacing.sm)
                }
                .font(OverlayType.callout)
            }
            Text(snapshot.hasScreenshot
                 ? "Screenshot input is recorded for this request. This source record does not contain an inspectable image."
                 : "Screenshot input is not marked in this source record.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Recorded request details") {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    Text("Turn: \(snapshot.turnID)\nThread: \(snapshot.threadID)\nSession: \(snapshot.sessionID)")
                        .font(OverlayType.monoMicro)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    recordedText("Evidence manifest", value: snapshot.evidenceManifest)
                    Text("Recorded request signals do not establish factual accuracy or verify the answer.")
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textSecondary)
                }
                .padding(.top, DesignTokens.Spacing.sm)
            }
            .font(OverlayType.callout)
        }
    }

    private func recordedText(_ title: String, value: String?, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(title).font(OverlayType.heading)
            if let note {
                Text(note)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
            }
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(value)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(value == nil ? "Not retained in this record." : "The recorded value is empty.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
