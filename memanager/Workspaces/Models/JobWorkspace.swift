import Foundation

/// Where a job application currently stands. Drives list ordering and the
/// status pill, and is written into the prompt brief so the model knows
/// whether it is helping with research, an interview loop, or an offer.
enum JobWorkspaceStatus: String, Codable, CaseIterable, Identifiable {
    case researching
    case applied
    case interviewing
    case offer
    case closed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .researching: return "Researching"
        case .applied: return "Applied"
        case .interviewing: return "Interviewing"
        case .offer: return "Offer"
        case .closed: return "Closed"
        }
    }

    var systemImage: String {
        switch self {
        case .researching: return "magnifyingglass"
        case .applied: return "paperplane"
        case .interviewing: return "person.2.wave.2"
        case .offer: return "envelope.open"
        case .closed: return "archivebox"
        }
    }

    /// Active pipelines first, closed last.
    var sortRank: Int {
        switch self {
        case .interviewing: return 0
        case .offer: return 1
        case .applied: return 2
        case .researching: return 3
        case .closed: return 4
        }
    }
}

/// One job pursuit: a folder on disk that collects everything about a role
/// plus the database row that indexes it. The folder is the durable,
/// portable artifact; the row is the fast lookup.
struct JobWorkspace: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var company: String
    var role: String
    var status: JobWorkspaceStatus
    var folderPath: String
    var folderBookmark: Data?
    var jobDescriptionSummary: String?
    var notes: String
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date?
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        name: String,
        company: String = "",
        role: String = "",
        status: JobWorkspaceStatus = .researching,
        folderPath: String,
        folderBookmark: Data? = nil,
        jobDescriptionSummary: String? = nil,
        notes: String = "",
        tags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.company = company
        self.role = role
        self.status = status
        self.folderPath = folderPath
        self.folderBookmark = folderBookmark
        self.jobDescriptionSummary = jobDescriptionSummary
        self.notes = notes
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
        self.isArchived = isArchived
    }

    var folderURL: URL {
        URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    /// Human title that always reads well even when only some fields are set.
    var displayTitle: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }
        let parts = [company, role].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Untitled Workspace" : parts.joined(separator: " ")
    }

    /// Secondary line: "Role at Company" when both are known.
    var subtitle: String {
        let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCompany = company.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmedRole.isEmpty, trimmedCompany.isEmpty) {
        case (false, false): return "\(trimmedRole) at \(trimmedCompany)"
        case (false, true): return trimmedRole
        case (true, false): return trimmedCompany
        case (true, true): return status.displayName
        }
    }
}
