import Foundation

/// The canonical shape of a workspace folder on disk. Everything that
/// reads or writes a workspace goes through these names so the layout can
/// evolve in one place.
enum WorkspaceFolderLayout {
    static let manifestFileName = "workspace.json"
    static let readmeFileName = "README.md"
    static let defaultRootFolderName = AppBrand.rolesFolder

    /// Subfolders created for every new workspace, in display order.
    static let provisionedCategories: [WorkspaceDocumentCategory] = [
        .jobDescription, .resume, .projects, .interviews, .notes, .journal
    ]

    /// Root level files that describe the workspace rather than the job.
    static let rootMetadataFileNames: Set<String> = [manifestFileName, readmeFileName]

    /// Files above this size are indexed by metadata only.
    static let maxExtractableBytes = 8_000_000

    /// Files above this size are fingerprinted by size instead of hashed.
    static let maxHashedBytes = 64_000_000

    /// Hard stop for one folder so an accidental import of a huge tree
    /// cannot run away.
    static let maxIndexedFiles = 2_000

    /// Directory names never descended into.
    static let skippedDirectoryNames: Set<String> = [
        "node_modules", "DerivedData", "build", ".build", "Pods", "dist", "target", "__pycache__", ".venv", "venv"
    ]

    static func category(forRelativePath relativePath: String) -> WorkspaceDocumentCategory {
        let firstComponent = relativePath.split(separator: "/").first.map(String.init) ?? ""
        return provisionedCategories.first(where: { $0.folderName == firstComponent }) ?? .other
    }

    /// File system safe folder name: "Stripe / Staff Engineer" becomes "Stripe Staff Engineer".
    static func folderName(for workspace: JobWorkspace) -> String {
        let raw = workspace.displayTitle
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character(" ") }
        let collapsed = String(cleaned)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let trimmed = String(collapsed.prefix(80))
        return trimmed.isEmpty ? "Workspace \(workspace.id.uuidString.prefix(8))" : trimmed
    }

    static func readmeContents(for workspace: JobWorkspace) -> String {
        """
        # \(workspace.displayTitle)

        This folder is an Abley Job Workspace. Drop anything about this role here
        and Abley will index it for Quick Assist context.

        \(provisionedCategories.map { "- `\($0.folderName)/` : \(readmeHint(for: $0))" }.joined(separator: "\n"))

        `\(manifestFileName)` mirrors the workspace metadata so the folder stays portable.
        """
    }

    private static func readmeHint(for category: WorkspaceDocumentCategory) -> String {
        switch category {
        case .jobDescription: return "the posting, requirements, team notes"
        case .resume: return "the resume or CV version tailored for this role"
        case .projects: return "write ups of projects and stories worth telling"
        case .interviews: return "round notes, interviewer names, questions asked"
        case .notes: return "anything else: research, comp, contacts"
        case .journal: return "auto appended log of problems worked through"
        case .other: return ""
        }
    }
}
