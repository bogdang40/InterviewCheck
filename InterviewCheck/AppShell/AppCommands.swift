import SwiftUI

/// The menu bar: File > New Interview / New Role, an Interview menu with the
/// live actions, and Window > Live Companion.
struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            NewItemCommands()
        }
        CommandMenu("Interview") {
            InterviewMenuItems()
        }
        CommandGroup(before: .windowArrangement) {
            CompanionMenuItem()
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to \(AppBrand.name)") { WelcomePresenter.shared.show() }
        }
    }
}

private struct NewItemCommands: View {
    @ObservedObject private var interview = InterviewController.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Interview") {
            openWindow(id: AppWindowID.main)
            AppNavigation.shared.show(.interview)
            interview.reset()
        }
        .keyboardShortcut("n")
        .disabled(interview.phase == .live)

        Button("New Role") {
            openWindow(id: AppWindowID.main)
            AppNavigation.shared.requestNewRole()
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
    }
}

private struct InterviewMenuItems: View {
    @ObservedObject private var interview = InterviewController.shared

    var body: some View {
        Button("Start Interview") { Task { await InterviewPermissions.shared.startInterview(interview) } }
            .keyboardShortcut("r")
            .disabled(!interview.canStart || interview.phase != .setup)
        Divider()
        Button("Question Asked") { interview.markQuestion() }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(interview.phase != .live)
        Button("Answer Done") { interview.answerDone() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(interview.activeQuestionID == nil)
        Divider()
        Button("End Interview") { interview.end() }
            .disabled(interview.phase != .live)
        Button("Show Report") {
            AppNavigation.shared.showReport(interview.interview?.id)
        }
        .disabled(interview.phase != .ended)
    }
}

private struct CompanionMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Live Companion") { openWindow(id: AppWindowID.companion) }
            .keyboardShortcut("l", modifiers: [.command, .option])
    }
}
