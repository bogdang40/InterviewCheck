import Foundation
import InterviewCheckConnectors

/// The few actions other apps and the system can trigger: the Dock menu,
/// interviewcheck:// links and Shortcuts all come through here.
@MainActor
enum InterviewAutomation {
    /// The next interview that has not ended yet.
    static func nextInterview(manager: ConnectorManager = .shared, now: Date = Date()) -> ExternalInterview? {
        manager.upcoming.first { ($0.endsAt ?? $0.startsAt.addingTimeInterval(3600)) > now }
    }

    /// Prepares the next interview; returns a sentence for the caller to show.
    @discardableResult
    static func prepareNext(manager: ConnectorManager = .shared, controller: InterviewController = .shared) async -> String {
        guard controller.phase != .live else { return "An interview is live." }
        guard let interview = nextInterview(manager: manager) else {
            return manager.accounts.isEmpty ? "Connect a calendar or ATS in Connections first." : "No upcoming interviews."
        }
        return await prepare(interview, manager: manager, controller: controller)
    }

    @discardableResult
    static func prepare(_ interview: ExternalInterview, manager: ConnectorManager = .shared,
                        controller: InterviewController = .shared) async -> String {
        let missing = await manager.prepare(interview, controller: controller)
        let who = interview.candidate?.name ?? interview.title
        let when = interview.startsAt.formatted(date: .omitted, time: .shortened)
        return (["Prepared \(who) at \(when)."] + missing).joined(separator: " ")
    }

    static func openLatestReport(database: SessionDatabase = .shared) -> String {
        guard let latest = database.loadInterviews(limit: 1).first else { return "No reports yet." }
        AppNavigation.shared.showReport(latest.id)
        return "Opened \(latest.candidateName.isEmpty ? "the latest report" : latest.candidateName)."
    }

    /// interviewcheck://prepare-next, interviewcheck://sync, interviewcheck://report/latest
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == AppBrand.urlScheme else { return false }
        switch url.host {
        case "prepare-next":
            Task { await prepareNext() }
        case "sync":
            Task { await ConnectorManager.shared.syncAll() }
        case "report" where url.path == "/latest":
            _ = openLatestReport()
        default:
            return false
        }
        return true
    }
}
