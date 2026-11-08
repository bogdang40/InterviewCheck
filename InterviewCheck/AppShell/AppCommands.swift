import SwiftUI

/// The menu bar: File > New Interview / New Role, an Interview menu with the
/// live actions, and Window > Live Companion.
struct AppCommands: Commands {
    var body: some Commands {
        SidebarCommands()
        CommandGroup(replacing: .newItem) {
            NewItemCommands()
        }
        CommandGroup(replacing: .printItem) {
            PrintReportItem()
        }
        CommandGroup(before: .sidebar) {
            SectionMenuItems()
            Divider()
        }
        CommandMenu("Interview") {
            InterviewMenuItems()
        }
        CommandGroup(before: .windowArrangement) {
            CompanionMenuItem()
            Divider()
        }
        CommandGroup(replacing: .help) {
            HelpMenuItems()
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

        Divider()
        Button("Analyze Recording\u{2026}") {
            openWindow(id: AppWindowID.main)
            RecordingAnalyzer.shared.present()
        }
        .keyboardShortcut("o")
        .disabled(interview.phase == .live)
    }
}

/// View › Interview / Roles / Reports with ⌘1–⌘3, like other Mac apps.
private struct SectionMenuItems: View {
    @ObservedObject private var navigation = AppNavigation.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
            Button(item.title) {
                openWindow(id: AppWindowID.main)
                navigation.show(item)
            }
            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
        }
    }
}

private struct PrintReportItem: View {
    @ObservedObject private var navigation = AppNavigation.shared

    var body: some View {
        Button("Print Report\u{2026}") {
            guard let id = navigation.selectedReportID,
                  let report = SessionDatabase.shared.loadInterviewReport(id: id) else { return }
            ReportExporter.print(report)
        }
        .keyboardShortcut("p")
        .disabled(navigation.selection != .reports || navigation.selectedReportID == nil)
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

private struct HelpMenuItems: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Welcome to \(AppBrand.name)") { WelcomePresenter.shared.show() }
        Button("Demo Interview") { openWindow(id: AppWindowID.demo) }
    }
}
