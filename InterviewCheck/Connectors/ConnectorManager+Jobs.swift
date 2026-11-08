import Foundation
import InterviewCheckConnectors

extension ConnectorManager {
    /// Connected systems that can list open jobs.
    var jobSources: [ConnectorKind] {
        accounts.map(\.kind).filter { (try? makeConnector($0)) is JobListing }
    }

    func openJobs(_ kind: ConnectorKind) async throws -> [ExternalJob] {
        guard let listing = try makeConnector(kind) as? JobListing else { return [] }
        return try await listing.openJobs().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Makes a role per job, with its full description, and drafts its
    /// questions in the background. Jobs already imported are skipped.
    @discardableResult
    func importJobs(_ jobs: [ExternalJob], from kind: ConnectorKind, roles: RoleStore = .shared) async -> [RoleProfile] {
        let connector = try? makeConnector(kind) as? JobSource
        var imported: [RoleProfile] = []
        for job in jobs {
            let key = "\(kind.rawValue):\(job.externalID)"
            guard !roles.roles.contains(where: { $0.externalJobKey == key }) else { continue }
            var description = job.description
            var title = job.title
            if description.isEmpty, let full = try? await connector?.job(id: job.externalID) {
                description = full.description
                if title == "Job" { title = full.title }
            }
            var role = roles.create(name: title, company: job.company ?? "")
            role.externalJobKey = key
            role.jobDescription = description
            roles.save(role)
            if !description.isEmpty { draftRole(role.id, roles: roles) }
            if let saved = roles.role(id: role.id) { imported.append(saved) }
        }
        return imported
    }
}
