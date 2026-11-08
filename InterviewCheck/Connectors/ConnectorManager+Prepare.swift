import Foundation
import InterviewCheckConnectors

extension ConnectorManager {
    /// Fills the interview setup from an upcoming interview: the candidate,
    /// a role with the job description, and the résumé. Returns what could
    /// not be filled, in plain words.
    ///
    /// A manual Prepare writes each part as soon as it is known (starting the
    /// interview meanwhile keeps the candidate and role). An automatic one
    /// passes `canApply`: everything is then written at once after the last
    /// wait, and only if `canApply` (given the role Prepare chose) agrees.
    @discardableResult
    func prepare(_ interview: ExternalInterview, controller: InterviewController,
                 roles: RoleStore = .shared, navigate: Bool = true, canApply: ((String?) -> Bool)? = nil) async -> [String] {
        guard controller.phase != .live else { return ["An interview is live."] }
        guard controller.pendingScoring.isEmpty else {
            let wait = Self.waitForScores
            controller.errorMessage = wait
            return [wait]
        }
        if controller.errorMessage == Self.waitForScores { controller.errorMessage = nil }
        prepareGeneration += 1
        let generation = prepareGeneration
        // Each await is a chance for the interview to start or another Prepare
        // to begin; then this one stops instead of overwriting the setup.
        let stopped = ["Preparation stopped: an interview started or another one is being prepared."]
        let current = { generation == self.prepareGeneration && controller.phase != .live }
        let original = interview
        let staged = canApply != nil
        controller.reset()
        controller.preparedFrom = original.id
        // Stopping leaves no half-made setup marked as this interview's.
        let stop = { () -> [String] in
            if generation == self.prepareGeneration, controller.preparedFrom == original.id, controller.externalRef == nil {
                controller.preparedFrom = nil
            }
            return stopped
        }
        // A calendar invite knows little: find the candidate in a connected ATS.
        let interview = await enriched(interview)
        guard current() else { return stop() }
        database.saveExternalLink(interview)
        if !staged {
            controller.candidateName = interview.candidate?.name ?? ""
            controller.externalRef = interview.id
        }
        var missing: [String] = []
        var roleID: String?
        var resume: (text: String, fileName: String)?
        let connector = try? makeConnector(interview.source)

        if let job = interview.job {
            let role = await role(for: job, source: interview.source, connector: connector, roles: roles)
            guard current() else { return stop() }
            roleID = role.id
            if !staged { roles.selectedRoleID = role.id }
            if role.jobDescription.isEmpty {
                missing.append("The job description was not available; paste it into the role.")
            } else if role.plannedQuestions.isEmpty, draftRole(role.id, roles: roles) {
                missing.append("Drafting questions and prompts for \(role.displayTitle) in the background.")
            }
        } else {
            missing.append("No job was attached; pick the role.")
        }

        if let sourceConnector = connector as? CandidateSource {
            do {
                // The full record adds the résumé and the link to the candidate's page.
                var candidate = interview.candidate
                if candidate?.resume == nil || candidate?.profileURL == nil, let id = candidate?.externalID {
                    let full = try await sourceConnector.candidate(id: id)
                    guard current() else { return stop() }
                    if var known = candidate {
                        known.resume = known.resume ?? full.resume
                        known.profileURL = known.profileURL ?? full.profileURL
                        known.email = known.email ?? full.email
                        candidate = known
                    }
                    var linked = interview
                    linked.candidate = candidate
                    database.saveExternalLink(linked)
                }
                if let file = candidate?.resume {
                    let text = try await resumeText(file, from: sourceConnector)
                    guard current() else { return stop() }
                    resume = (text, file.filename)
                } else {
                    missing.append("No r\u{00E9}sum\u{00E9} on file.")
                }
            } catch {
                missing.append("The r\u{00E9}sum\u{00E9} could not be downloaded: \(error.localizedDescription)")
            }
        }

        // No résumé from an ATS: one a recruiter emailed (connected mailbox).
        // Only when the interviewer asked (the "check it" note is shown to them);
        // an automatic Prepare has nowhere to show it.
        if resume == nil, !staged, let candidate = interview.candidate,
           let found = await emailedResume(for: candidate, current: current) {
            guard current() else { return stop() }
            resume = (found.text, found.filename)
            missing.removeAll { $0 == "No r\u{00E9}sum\u{00E9} on file." }
            missing.append("R\u{00E9}sum\u{00E9} from mail: \(found.filename) (\(found.origin)). Check it is this candidate\u{2019}s.")
        }

        guard current(), canApply?(roleID) ?? true else { return stop() }
        // A manual Prepare already wrote the candidate and role; anything the
        // interviewer changed during the downloads stays. The résumé goes in
        // only if the field is still empty.
        if staged {
            controller.candidateName = interview.candidate?.name ?? ""
            controller.externalRef = interview.id
            if let roleID { roles.selectedRoleID = roleID }
        }
        controller.preparedFrom = original.id
        if let resume, staged || controller.resumeText.isEmpty {
            controller.resumeText = resume.text
            controller.resumeFileName = resume.fileName
        }
        if navigate { AppNavigation.shared.show(.interview) }
        return missing
    }

    static let waitForScores = "The last interview\u{2019}s scores are still being worked out. Prepare again in a moment."

    /// For interviews from calendars and meeting tools: the same interview as
    /// the connected ATS sees it (candidate, job, application), found by the
    /// candidate's email. Unchanged when nothing matches.
    func enriched(_ interview: ExternalInterview) async -> ExternalInterview {
        guard [.calendar, .mail, .scheduling, .meetings].contains(interview.source.descriptor.category),
              let email = interview.candidate?.email else { return interview }
        for account in accounts where [.ats, .unified].contains(account.kind.descriptor.category) {
            guard let lookup = try? makeConnector(account.kind) as? CandidateLookup,
                  let match = try? await lookup.findCandidate(email: email) else { continue }
            var found = interview
            found.source = account.kind
            found.candidate = match.candidate
            found.job = match.job ?? interview.job
            found.applicationID = match.applicationID
            if found.meetingURL == nil { found.meetingURL = interview.meetingURL }
            return found
        }
        return interview
    }

    /// A new role from an ATS job gets its questions and tailored cheater
    /// prompts drafted in the background with the AI key already set up.
    /// Returns false when there is no usable AI key.
    @discardableResult
    func draftRole(_ roleID: String, roles: RoleStore, settings: DetectorSettings = .shared) -> Bool {
        guard let entry = settings.usableJudge() ?? settings.usableLineup().first,
              let client = try? DetectorTextClientFactory.make(provider: entry.provider, model: entry.model) else { return false }
        Task { @MainActor in
            guard let role = roles.role(id: roleID), role.jobDescription.count >= 40,
                  let draft = try? await RoleDraftService.draft(roleTitle: role.displayTitle, jobDescription: role.jobDescription,
                                                                using: client),
                  let current = roles.role(id: roleID), current.plannedQuestions.isEmpty else { return }
            roles.save(RoleDraftService.apply(draft, to: current))
        }
        return true
    }

    /// The role for a job: the one already made from it, one with the same
    /// title, or a new one with the job description.
    private func role(for job: ExternalJob, source: ConnectorKind, connector: Connector?, roles: RoleStore) async -> RoleProfile {
        let key = job.externalID.isEmpty ? nil : "\(source.rawValue):\(job.externalID)"
        var role = roles.roles.first { key != nil && $0.externalJobKey == key }
            ?? (job.title == "Job" ? nil : roles.roles.first { $0.name.caseInsensitiveCompare(job.title) == .orderedSame })
            ?? roles.create(name: job.title, company: job.company ?? "")
        if role.externalJobKey == nil { role.externalJobKey = key }
        if role.jobDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || role.name == "Job" {
            var description = job.description
            if description.isEmpty, !job.externalID.isEmpty, let jobs = connector as? JobSource,
               let full = try? await jobs.job(id: job.externalID) {
                description = full.description
                if role.name == "Job" || role.name.isEmpty { role.name = full.title }
            }
            if role.jobDescription.isEmpty { role.jobDescription = description }
        }
        roles.save(role)
        return roles.role(id: role.id) ?? role
    }

    /// A résumé attached to a recent email, from the first connected mailbox
    /// that has one; its text is read and the file deleted.
    private func emailedResume(for candidate: ExternalCandidate,
                               current: () -> Bool) async -> (text: String, filename: String, origin: String)? {
        for account in accounts {
            guard current(), let finder = try? makeConnector(account.kind) as? ResumeFinder else { continue }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("interviewcheck-mail-\(UUID().uuidString)")
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { continue }
            defer { try? FileManager.default.removeItem(at: folder) }
            guard let found = try? await finder.findResume(for: candidate, into: folder),
                  let text = try? DocumentText.read(found.file),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return (text, found.filename, found.origin)
        }
        return nil
    }

    /// Downloads the résumé to a temporary file, reads its text, deletes it.
    private func resumeText(_ file: ExternalFile, from connector: CandidateSource) async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("interviewcheck-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = try await connector.download(file, into: folder)
        return try DocumentText.read(local)
    }
}
