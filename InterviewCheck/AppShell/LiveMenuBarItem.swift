import InterviewCheckKit
import SwiftUI

/// A menu bar item that exists only while an interview is live, so the
/// interviewer can mark questions from any app, even a full-screen call.
struct LiveMenuBarContent: View {
    @ObservedObject var controller: InterviewController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let interview = controller.interview {
            Text("Interviewing \(interview.candidateName.isEmpty ? "candidate" : interview.candidateName)")
        }
        if let question = controller.activeQuestion ?? controller.questions.last {
            Text("Q\(question.ordinal): \(question.text.isEmpty ? "listening\u{2026}" : String(question.text.prefix(60)))")
            if let score = controller.scores[question.id] {
                Text("\(score.percent)% \u{00B7} \(ScoreBand(percent: score.percent).title)")
            }
        }
        Divider()
        Button("Question Asked") { controller.markQuestion() }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
        Button("Answer Done") { controller.answerDone() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(controller.activeQuestionID == nil)
        Divider()
        Button("Show Live Companion") { openWindow(id: AppWindowID.companion) }
        Button("Show Main Window") {
            openWindow(id: AppWindowID.main)
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("End Interview") { controller.end() }
    }
}

/// The icon: a recording dot, with the latest score when there is one.
struct LiveMenuBarLabel: View {
    @ObservedObject var controller: InterviewController

    var body: some View {
        let last = controller.questions.last.flatMap { controller.scores[$0.id] }
        if let last {
            Label("\(last.percent)%", systemImage: "record.circle")
        } else {
            Image(systemName: "record.circle")
        }
    }
}
