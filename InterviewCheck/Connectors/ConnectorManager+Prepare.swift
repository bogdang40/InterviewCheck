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
        controller.reset()
        controller.candidateName = interview.candidate?.name ?? ""
        controller.externalRef = interview.id
        database.saveExternalLink(interview)
        var missing: [String] = []
        let connector = try? makeConnector(interview.source)

        if let job = interview.job {
            let role = await role(for: job, source: interview.source, connector: connector, roles: roles)
            roles.selectedRoleID = role.id
            if role.jobDescription.isEmpty { missing.append("The job description was not available; paste it into the role.") }
        } else {
            missing.append("No job was attached; pick the role.")
        }

        if let sourceConnector = connector as? CandidateSource {
            do {
                var resume = interview.candidate?.resume
                if resume == nil, let id = interview.candidate?.externalID {
                    resume = try await sourceConnector.candidate(id: id).resume
                }
                if let resume {
                    try await loadResume(resume, from: sourceConnector, into: controller)
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

    /// The role for a job: the one already made from it, one with the same
    /// title, or a new one with the job description.
    private func role(for job: ExternalJob, source: ConnectorKind, connector: Connector?, roles: RoleStore) async -> RoleProfile {
        let key = job.externalID.isEmpty ? nil : "\(source.rawValue):\(job.externalID)"
        var role = roles.roles.first { key != nil && $0.externalJobKey == key }
            ?? roles.roles.first { $0.name.caseInsensitiveCompare(job.title) == .orderedSame }
            ?? roles.create(name: job.title, company: job.company ?? "")
        if role.externalJobKey == nil { role.externalJobKey = key }
        if role.jobDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var description = job.description
            if description.isEmpty, !job.externalID.isEmpty, let jobs = connector as? JobSource {
                description = (try? await jobs.job(id: job.externalID).description) ?? ""
            }
            role.jobDescription = description
        }
        roles.save(role)
        return roles.role(id: role.id) ?? role
    }

    /// Downloads the résumé to a temporary file, reads its text, deletes it.
    private func loadResume(_ file: ExternalFile, from connector: CandidateSource,
                            into controller: InterviewController) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("interviewcheck-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = try await connector.download(file, into: folder)
        controller.resumeText = try DocumentText.read(local)
        controller.resumeFileName = file.filename
    }
}
