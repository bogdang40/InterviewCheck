import SwiftUI

/// Resume banner pinned under the summary. Resuming rehydrates the
/// transcript and thread; audio capture stays paused until the user hits
/// their start key, so nothing records by surprise.
struct ResumeSessionBar: View {
    let sessionID: String

    var body: some View {
        ToneBanner(
            tone: .info,
            title: "Resume this session",
            message: "Rehydrates the transcript and thread. The mic stays paused until you start it.",
            systemImage: "play.circle",
            actions: [BannerAction(title: "Resume", kind: .primary, action: resume)]
        )
    }

    private func resume() {
        guard let uuid = UUID(uuidString: sessionID) else { return }
        SessionController.shared.resumeSession(sessionID: uuid)
    }
}
