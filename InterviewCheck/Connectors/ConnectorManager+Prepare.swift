import Foundation
import InterviewCheckConnectors

extension ConnectorManager {
    /// Fills the interview setup from an upcoming interview: the candidate,
    /// a role with the job description, and the résumé. Returns what could
    /// not be filled, in plain words.
    @discardableResult
    func prepare(_ interview: ExternalInterview, controller: InterviewController,
                 roles: RoleStore = .shared) async -> [String] {
        guard controller.phase != .live else { return ["An interview is live."] }
        prepareGeneration += 1
        let generation = prepareGeneration
        // Each await is a chance for the interview to start or another Prepare
        // to begin; then this one stops instead of overwriting the setup.
        let stopped = ["Preparation stopped: an interview started or another one is being prepared."]
        let current = { generation == self.prepareGeneration && controller.phase != .live }
        let original = interview
        controller.reset()
        controller.preparedFrom = original.id
        // A calendar invite knows little: find the candidate in a connected ATS.
        let interview = await enriched(interview)
        guard current() else { return stopped }
        controller.candidateName = interview.candidate?.name ?? ""
        controller.externalRef = interview.id
        controller.preparedFrom = original.id
        database.saveExternalLink(interview)
        var missing: [String] = []
        let connector = try? makeConnector(interview.source)

        if let job = interview.job {
            let role = await role(for: job, source: interview.source, connector: connector, roles: roles)
            guard current() else { return stopped }
            roles.selectedRoleID = role.id
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
                    guard current() else { return stopped }
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
                if let resume = candidate?.resume {
                    let text = try await resumeText(resume, from: sourceConnector)
                    guard current() else { return stopped }
                    controller.resumeText = text
                    controller.resumeFileName = resume.filename
                } else {
                    missing.append("No r\u{00E9}sum\u{00E9} on file.")
                }
            } catch {
                missing.append("The r\u{00E9}sum\u{00E9} could not be downloaded: \(error.localizedDescription)")
            }
        }
        AppNavigation.shared.show(.interview)
        return missing
    }

    /// For interviews from calendars and meeting tools: the same interview as
    /// the connected ATS sees it (candidate, job, application), found by the
    /// candidate's email. Unchanged when nothing matches.
    func enriched(_ interview: ExternalInterview) async -> ExternalInterview {
        guard [.calendar, .mail, .meetings].contains(interview.source.descriptor.category),
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

    /// Downloads the résumé to a temporary file, reads its text, deletes it.
    private func resumeText(_ file: ExternalFile, from connector: CandidateSource) async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("interviewcheck-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = try await connector.download(file, into: folder)
        return try DocumentText.read(local)
    }
}
