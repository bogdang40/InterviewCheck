import Foundation

/// On disk mirror of the workspace row, so a folder copied to another
/// machine can be re-imported with its identity and metadata intact.
struct WorkspaceManifest: Codable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var id: UUID
    var name: String
    var company: String
    var role: String
    var status: JobWorkspaceStatus
    var tags: [String]
    var jobDescriptionSummary: String?
    var createdAt: Date
    var updatedAt: Date

    init(workspace: JobWorkspace) {
        formatVersion = WorkspaceManifest.currentFormatVersion
        id = workspace.id
        name = workspace.name
        company = workspace.company
        role = workspace.role
        status = workspace.status
        tags = workspace.tags
        jobDescriptionSummary = workspace.jobDescriptionSummary
        createdAt = workspace.createdAt
        updatedAt = workspace.updatedAt
    }

    /// Rebuild a workspace record from a manifest found in `folderURL`.
    func makeWorkspace(folderURL: URL) -> JobWorkspace {
        JobWorkspace(
            id: id,
            name: name,
            company: company,
            role: role,
            status: status,
            folderPath: folderURL.path,
            jobDescriptionSummary: jobDescriptionSummary,
            tags: tags,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func url(in folderURL: URL) -> URL {
        folderURL.appendingPathComponent(WorkspaceFolderLayout.manifestFileName)
    }

    func write(to folderURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: WorkspaceManifest.url(in: folderURL), options: .atomic)
    }

    static func read(from folderURL: URL) -> WorkspaceManifest? {
        guard let data = try? Data(contentsOf: url(in: folderURL)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WorkspaceManifest.self, from: data)
    }
}
