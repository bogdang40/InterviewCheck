import AppKit
import InterviewCheckConnectors

/// The few actions other apps and the system can trigger: the Dock menu,
/// interviewcheck:// links and Shortcuts all come through here.
@MainActor
enum InterviewAutomation {
    /// The next interview that has not ended yet.
    /// The next of the user's interviews not over yet, skipping the one just run.
    static func nextInterview(manager: ConnectorManager = .shared, controller: InterviewController = .shared,
                              now: Date = Date()) -> ExternalInterview? {
        manager.mine.first { interview in
            (interview.endsAt ?? interview.startsAt.addingTimeInterval(3600)) > now
                && !(controller.phase == .ended && manager.holds(interview, in: controller))
        }
    }

    /// Prepares the next interview; returns a sentence for the caller to show.
    @discardableResult
    static func prepareNext(manager: ConnectorManager = .shared, controller: InterviewController = .shared,
                            mailResumes: Bool = false) async -> String {
        guard controller.phase != .live else { return "An interview is live." }
        guard let interview = nextInterview(manager: manager, controller: controller) else {
            return manager.accounts.isEmpty ? "Connect a calendar, mailbox or ATS in Connections first." : "No upcoming interviews."
        }
        return await prepare(interview, manager: manager, controller: controller, mailResumes: mailResumes)
    }

    @discardableResult
    static func prepare(_ interview: ExternalInterview, manager: ConnectorManager = .shared,
                        controller: InterviewController = .shared, mailResumes: Bool = false) async -> String {
        let missing = await manager.prepare(interview, controller: controller, mailResumes: mailResumes)
        // Refused or stopped: say only that, not "Prepared …".
        if let first = missing.first, first == ConnectorManager.waitForScores || first.hasPrefix("Preparation stopped")
            || first == "An interview is live." {
            return first
        }
        let who = interview.candidate?.name ?? interview.title
        let when = interview.startsAt.formatted(date: .omitted, time: .shortened)
        return (["Prepared \(who) at \(when)."] + missing).joined(separator: " ")
    }

    /// Prepares the next interview (unless the setup already holds it) and
    /// opens its meeting link.
    @discardableResult
    static func joinNext(manager: ConnectorManager = .shared, controller: InterviewController = .shared,
                         open: (URL) -> Void = { NSWorkspace.shared.open($0) },
                         joined: @MainActor (String) -> Void = { AutoPrepare.shared.markJoined($0) },
                         mailResumes: Bool = false) async -> String {
        guard controller.phase != .live else { return "An interview is live." }
        guard let interview = nextInterview(manager: manager, controller: controller) else {
            return manager.accounts.isEmpty ? "Connect a calendar, mailbox or ATS in Connections first." : "No upcoming interviews."
        }
        var said: [String] = []
        if !manager.holds(interview, in: controller) {
            said.append(await prepare(interview, manager: manager, controller: controller, mailResumes: mailResumes))
        }
        guard let link = interview.meetingURL else { return (said + ["This interview has no meeting link."]).joined(separator: " ") }
        open(link)
        joined(interview.id)
        return (said + ["Opened the \(MeetingLinks.platform(of: link).title) link."]).joined(separator: " ")
    }

    static func openLatestReport(database: SessionDatabase = .shared) -> String {
        guard let latest = database.loadInterviews(limit: 1).first else { return "No reports yet." }
        AppNavigation.shared.showReport(latest.id)
        return "Opened \(latest.candidateName.isEmpty ? "the latest report" : latest.candidateName)."
    }

    /// interviewcheck://prepare-next, interviewcheck://join-next, interviewcheck://sync, interviewcheck://report/latest
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == AppBrand.urlScheme else { return false }
        switch url.host {
        case "prepare-next":
            Task { await prepareNext() }
        case "join-next":
            Task { await joinNext() }
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
