import AppKit
import InterviewCheckConnectors

/// Gets the next interview ready by itself a few minutes before it starts:
/// the candidate, the role with its job description, and the résumé, as
/// Prepare does. It never starts the interview or confirms the candidate was
/// told, and never replaces setup the interviewer typed in.
@MainActor
final class AutoPrepare {
    static let shared = AutoPrepare()
    static let enabledKey = "interviewcheck.autoPrepare"

    /// On unless turned off in Connections.
    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    static let joinKey = "interviewcheck.autoJoin"

    /// Opens the prepared interview's meeting a minute before it starts. Off
    /// unless turned on in Connections.
    var joinsAutomatically: Bool {
        get { defaults.object(forKey: Self.joinKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Self.joinKey) }
    }
    var openLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Interviews whose meeting was opened (by hand or automatically).
    private(set) var joinedIDs: Set<String> = []

    /// The reminder's lead time, or 10 minutes with reminders off.
    var leadMinutes: () -> Int = { InterviewReminders.minutes > 0 ? InterviewReminders.minutes : 10 }
    var now: () -> Date = { Date() }
    /// The Roles editor is in front: changing the selected role would switch it.
    var isEditingRoles: () -> Bool = { AppNavigation.shared.selection == .roles }

    private let manager: ConnectorManager
    private let controller: InterviewController
    private let roles: RoleStore
    private let defaults: UserDefaults
    private var timer: Timer?
    /// Interviews already prepared automatically (each only once).
    private(set) var preparedIDs: Set<String> = []
    /// The setup as the last automatic Prepare left it, and for which interview.
    private var lastFill: Fill?
    private var lastPrepared: ExternalInterview?

    struct Fill: Equatable {
        var preparedFrom: String?
        var candidate: String
        var resume: Int
        var consent: Bool
        var role: String?
    }

    init(manager: ConnectorManager = .shared, controller: InterviewController = .shared, roles: RoleStore = .shared,
         defaults: UserDefaults = AppDefaults.standard) {
        self.manager = manager
        self.controller = controller
        self.roles = roles
        self.defaults = defaults
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await tick() }
    }

    /// Prepares the interview that is due, if the setup is free. Returns it
    /// when its details were filled in.
    @discardableResult
    func tick() async -> ExternalInterview? {
        joinIfDue()
        guard isEnabled, !isEditingRoles(),
              let next = Self.due(manager.mine, now: now(), leadMinutes: leadMinutes(), prepared: preparedIDs),
              setupIsFree(for: next) else { return nil }
        preparedIDs.insert(Self.key(next))
        let role = roles.selectedRoleID
        let generation = manager.prepareGeneration
        // Written only if, after the downloads, the setup is still as Prepare
        // left it: nothing typed, consent not ticked, Roles not opened.
        await manager.prepare(next, controller: controller, roles: roles, navigate: false, canApply: { [weak self] chosen in
            guard let self else { return false }
            // The role Prepare picked (a new role selects itself) is not a change by the interviewer.
            let selected = self.roles.selectedRoleID
            return self.controller.phase == .setup && !self.controller.consentConfirmed
                && self.controller.candidateName.isEmpty && self.controller.resumeText.isEmpty
                && self.controller.preparedFrom == next.id && !self.isEditingRoles() && (selected == role || selected == chosen)
        })
        guard manager.prepareGeneration == generation + 1, controller.preparedFrom == next.id,
              controller.externalRef != nil else { return nil }
        lastFill = fill
        lastPrepared = next
        return next
    }

    /// The Join button was used: the meeting is not opened a second time.
    func markJoined(_ id: String) {
        joinedIDs.insert(id)
    }

    /// Opens the meeting of the interview the setup holds, from 90 seconds
    /// before its start until 10 minutes after; once per interview.
    @discardableResult
    func joinIfDue() -> URL? {
        guard joinsAutomatically, controller.phase == .setup, controller.externalRef != nil, let prepared = controller.preparedFrom,
              let interview = manager.mine.first(where: { manager.holds($0, in: controller) }),
              !joinedIDs.contains(interview.id), !joinedIDs.contains(prepared), let link = interview.meetingURL else { return nil }
        let id = interview.id
        let untilStart = interview.startsAt.timeIntervalSince(now())
        guard untilStart <= 90, untilStart > -10 * 60 else { return nil }
        joinedIDs.insert(id)
        openLink(link)
        return link
    }

    /// The first interview starting within the lead time (or started in the
    /// last five minutes) that was not prepared automatically yet.
    /// Id and start: an interview moved to another time is prepared again then.
    static func key(_ interview: ExternalInterview) -> String {
        "\(interview.id)@\(Int(interview.startsAt.timeIntervalSince1970))"
    }

    static func due(_ upcoming: [ExternalInterview], now: Date, leadMinutes: Int, prepared: Set<String>) -> ExternalInterview? {
        upcoming.first {
            !prepared.contains(key($0)) && $0.startsAt > now.addingTimeInterval(-5 * 60)
                && $0.startsAt <= now.addingTimeInterval(Double(leadMinutes) * 60)
        }
    }

    /// Empty, or still exactly what the last automatic Prepare filled in for
    /// an interview that is over: kept until its end when known; with no end,
    /// an hour but released 5 minutes before `next`, never in its first 15 minutes.
    func setupIsFree(for next: ExternalInterview) -> Bool {
        // A finished interview whose scores are all in is saved: the next may come in.
        // (Not the interview that just ended, prepared by hand or started early.)
        if controller.phase == .ended {
            return controller.pendingScoring.isEmpty && controller.referencesInFlight.isEmpty && !manager.holds(next, in: controller)
        }
        guard controller.phase == .setup, controller.pendingScoring.isEmpty, !controller.consentConfirmed else { return false }
        if controller.candidateName.isEmpty, controller.resumeText.isEmpty, controller.externalRef == nil,
           controller.preparedFrom == nil { return true }
        guard let lastFill, lastFill == fill, let lastPrepared else { return false }
        // Cancelled or moved since (no longer among the user's interviews): let it go.
        guard manager.mine.contains(where: { ($0.id == lastPrepared.id || ConnectorManager.sameInterview($0, lastPrepared))
            && abs($0.startsAt.timeIntervalSince(lastPrepared.startsAt)) < 60 }) else { return true }
        let keepUntil: Date
        if let end = lastPrepared.endsAt {
            // A known end: kept until then, even if the next one overlaps.
            keepUntil = end
        } else {
            // No end given: an hour, but released 5 minutes before the next
            // interview, and never in its first 15 minutes.
            keepUntil = max(min(lastPrepared.startsAt.addingTimeInterval(3600), next.startsAt.addingTimeInterval(-5 * 60)),
                            lastPrepared.startsAt.addingTimeInterval(15 * 60))
        }
        return now() >= keepUntil
    }

    private var fill: Fill {
        Fill(preparedFrom: controller.preparedFrom, candidate: controller.candidateName, resume: controller.resumeText.count,
             consent: controller.consentConfirmed, role: roles.selectedRoleID)
    }
}
