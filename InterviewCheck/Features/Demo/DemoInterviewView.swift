import SwiftUI

/// Help › Demo Interview: a scripted interview in its own window.
struct DemoInterviewView: View {
    @StateObject private var demo = DemoInterview()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle").foregroundStyle(Color.accentColor)
                Text("Demo: a scripted interview. No microphone, no keys, nothing saved to your reports.")
                    .font(.callout)
                Spacer()
                Button("Restart") { demo.restart() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()
            switch demo.controller.phase {
            case .setup:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .live, .ended:
                InterviewLiveScreen(controller: demo.controller, timeline: demo.timeline, showsAudioStatus: false)
            }
        }
        .onAppear { demo.start() }
        .onDisappear { demo.stop() }
    }
}
