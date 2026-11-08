import SwiftUI

/// Help › Demo Interview: a scripted interview in its own window, ending on
/// the report it produced.
struct DemoInterviewView: View {
    @StateObject private var demo = DemoInterview()
    @State private var showsReport = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            Divider()
            if showsReport, let report = demo.report {
                ReportDetail(report: report, database: demo.controller.database)
                    .id(report.interview.id)
            } else {
                switch demo.controller.phase {
                case .setup:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .live, .ended:
                    InterviewLiveScreen(controller: demo.controller, timeline: demo.timeline, showsAudioStatus: false)
                }
            }
        }
        .onAppear { demo.start() }
        .onDisappear { demo.stop() }
        .onChange(of: demo.isFinished) { _, finished in
            withAnimation(.easeInOut(duration: 0.25)) { showsReport = finished }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: demo.isFinished ? "checkmark.seal" : "play.rectangle").foregroundStyle(Color.accentColor)
            if demo.isFinished, let interview = demo.report?.interview {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Demo finished: the report this interview produced").font(.callout.weight(.semibold))
                    if let overall = interview.overallPercent {
                        Text("\(overall)% overall \u{00B7} \(interview.flaggedCount) of \(interview.questionCount) answers flagged \u{00B7} nothing saved to your reports")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Picker("Show", selection: $showsReport) {
                    Text("Interview").tag(false)
                    Text("Report").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Demo: a scripted 90-second interview").font(.callout.weight(.semibold))
                    Text("One honest answer, one read from an AI tool, one in between. No microphone, no keys, nothing saved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Button("Restart") {
                showsReport = false
                demo.restart()
            }
        }
    }
}
