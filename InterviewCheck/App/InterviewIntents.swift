import AppIntents

/// Shortcuts actions: prepare the next interview, sync, open the latest report.
struct PrepareNextInterviewIntent: AppIntent {
    static let title: LocalizedStringResource = "Prepare Next Interview"
    static let description = IntentDescription("Fills in the next interview's candidate, role, job description and résumé from your connected calendar or ATS.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await InterviewAutomation.prepareNext()))
    }
}

struct SyncConnectionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Interview Connections"
    static let description = IntentDescription("Checks every connected calendar, ATS and meeting tool for interviews and recordings.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await ConnectorManager.shared.syncAll()
        let count = ConnectorManager.shared.upcoming.count
        return .result(dialog: IntentDialog(stringLiteral: "\(count) upcoming interview\(count == 1 ? "" : "s")."))
    }
}

struct OpenLatestReportIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Latest Interview Report"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: InterviewAutomation.openLatestReport()))
    }
}

struct InterviewShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PrepareNextInterviewIntent(), phrases: ["Prepare my next interview in \(.applicationName)"],
                    shortTitle: "Prepare Next Interview", systemImageName: "person.badge.clock")
        AppShortcut(intent: SyncConnectionsIntent(), phrases: ["Sync \(.applicationName)"],
                    shortTitle: "Sync Connections", systemImageName: "arrow.clockwise")
        AppShortcut(intent: OpenLatestReportIntent(), phrases: ["Open my latest \(.applicationName) report"],
                    shortTitle: "Latest Report", systemImageName: "doc.text.magnifyingglass")
    }
}
