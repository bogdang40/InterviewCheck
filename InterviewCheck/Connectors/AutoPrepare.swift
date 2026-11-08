import Foundation
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
    /// The setup as the last automatic Prepare left it.
    private var lastFill: Fill?

    struct Fill: Equatable {
        var preparedFrom: String?
        var candidate: String
        var resume: Int
        var consent: Bool
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

    /// Prepares the interview that is due, if the setup is free. Returns it.
    @discardableResult
    func tick() async -> ExternalInterview? {
        guard isEnabled, !isEditingRoles(),
              let next = Self.due(manager.upcoming, now: now(), leadMinutes: leadMinutes(), prepared: preparedIDs),
              setupIsFree else { return nil }
        preparedIDs.insert(next.id)
        await manager.prepare(next, controller: controller, roles: roles, navigate: false)
        lastFill = fill
        return next
    }

    /// The first interview starting within the lead time (or started in the
    /// last five minutes) that was not prepared automatically yet.
    static func due(_ upcoming: [ExternalInterview], now: Date, leadMinutes: Int, prepared: Set<String>) -> ExternalInterview? {
        upcoming.first {
            !prepared.contains($0.id) && $0.startsAt > now.addingTimeInterval(-5 * 60)
                && $0.startsAt <= now.addingTimeInterval(Double(leadMinutes) * 60)
        }
    }

    /// Empty, or still exactly what the last automatic Prepare filled in.
    var setupIsFree: Bool {
        guard controller.phase == .setup, controller.pendingScoring.isEmpty, !controller.consentConfirmed else { return false }
        if controller.candidateName.isEmpty, controller.resumeText.isEmpty, controller.externalRef == nil { return true }
        return lastFill != nil && lastFill == fill
    }

    private var fill: Fill {
        Fill(preparedFrom: controller.preparedFrom, candidate: controller.candidateName, resume: controller.resumeText.count,
             consent: controller.consentConfirmed)
    }
}
