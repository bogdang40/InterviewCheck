import SwiftUI

/// Loads the meeting minutes style summary for a session and keeps it in
/// sync with generation notifications. Rendering lives in
/// `SessionSummaryContent`.
struct SessionSummaryView: View {
    let sessionID: String?

    @State private var summary: SessionSummary?
    @State private var isRegenerating = false
    @State private var generationID = UUID()
    @State private var generationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SurfaceHeader("Summary", systemImage: "list.bullet.clipboard", prominence: .heading) {
                if isRegenerating {
                    ProgressView()
                        .controlSize(.small)
                }
                if summary?.status == .completed {
                    Button("Regenerate", action: regenerate)
                        .buttonStyle(.overlay(.ghost, size: .small))
                        .disabled(isRegenerating)
                }
            }
            if let generationError {
                ToneBanner(tone: .critical, title: "Previous summary retained", message: generationError, actions: [BannerAction(title: "Retry", action: regenerate)])
            }
            if let sessionID, !sessionID.isEmpty {
                SessionSummaryContent(
                    sessionID: sessionID,
                    summary: summary,
                    isRegenerating: isRegenerating,
                    onGenerate: regenerate
                )
            } else {
                Text("Select a session to see its summary.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .overlayCard(.base)
        .onAppear(perform: loadIfAvailable)
        .onChange(of: sessionID) { _, _ in
            generationID = UUID()
            isRegenerating = false
            summary = nil
            generationError = nil
            loadIfAvailable()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionSummaryDidChange)) { notification in
            guard let sessionID,
                  let updated = notification.userInfo?[SessionSummaryNotificationUserInfo.sessionID] as? String,
                  updated == sessionID else { return }
            loadIfAvailable()
        }
    }

    private func loadIfAvailable() {
        guard let sessionID, let uuid = UUID(uuidString: sessionID) else {
            summary = nil
            return
        }
        let loaded = SessionSummaryComposer.shared.loadCached(sessionID: uuid)
        let hasPriorContent = summary?.status == .completed || summary?.status == .heuristic
        if hasPriorContent, loaded?.status == .generating || loaded?.status == .pending {
            isRegenerating = true
            return
        }
        if hasPriorContent, loaded?.status == .failed {
            generationError = loaded?.errorMessage ?? "Summary generation failed. You can retry."
            isRegenerating = false
            return
        }
        summary = loaded
        generationError = nil
        isRegenerating = loaded?.status == .generating || loaded?.status == .pending
    }

    private func regenerate() {
        guard !isRegenerating, let sessionID, let uuid = UUID(uuidString: sessionID) else { return }
        isRegenerating = true
        generationError = nil
        let requestID = UUID()
        generationID = requestID
        Task {
            await SessionSummaryComposer.shared.generate(sessionID: uuid)
            await MainActor.run {
                guard generationID == requestID, self.sessionID == sessionID else { return }
                isRegenerating = false
                loadIfAvailable()
            }
        }
    }
}
