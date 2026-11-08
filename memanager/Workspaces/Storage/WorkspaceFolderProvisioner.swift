import Foundation

enum WorkspaceFolderError: Error, LocalizedError {
    case rootUnavailable(String)
    case folderMissing(String)
    case notADirectory(String)

    var errorDescription: String? {
        switch self {
        case .rootUnavailable(let path): return "Could not create the workspaces folder at \(path)."
        case .folderMissing(let path): return "The workspace folder no longer exists at \(path)."
        case .notADirectory(let path): return "\(path) is not a folder."
        }
    }
}

protocol WorkspaceFolderProvisioning {
    /// Creates the folder skeleton for a new workspace and returns its URL.
    func provision(_ workspace: JobWorkspace) throws -> URL
    /// Validates an existing folder and lays down any missing skeleton pieces.
    func adopt(existingFolder url: URL, for workspace: JobWorkspace) throws
    /// Rewrites the manifest after metadata changes.
    func writeManifest(for workspace: JobWorkspace) throws
    var rootDirectory: URL { get }
}

/// Owns the on disk lifecycle of workspace folders. Never deletes user
/// files; deletion of a folder is left to Finder on purpose.
final class WorkspaceFolderProvisioner: WorkspaceFolderProvisioning {
    let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? WorkspaceFolderProvisioner.defaultRootDirectory(fileManager: fileManager)
    }

    static func defaultRootDirectory(fileManager: FileManager = .default) -> URL {
        if TestRuntime.isRunningUnitTests {
            return TestRuntime.temporaryDirectory.appendingPathComponent("workspaces", isDirectory: true)
        }
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return documents.appendingPathComponent(WorkspaceFolderLayout.defaultRootFolderName, isDirectory: true)
    }

    func provision(_ workspace: JobWorkspace) throws -> URL {
        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        } catch {
            throw WorkspaceFolderError.rootUnavailable(rootDirectory.path)
        }
        let folderURL = uniqueFolderURL(for: workspace)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        var provisioned = workspace
        provisioned.folderPath = folderURL.path
        try layDownSkeleton(in: folderURL, for: provisioned)
        return folderURL
    }

    func adopt(existingFolder url: URL, for workspace: JobWorkspace) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw WorkspaceFolderError.folderMissing(url.path)
        }
        guard isDirectory.boolValue else {
            throw WorkspaceFolderError.notADirectory(url.path)
        }
        var adopted = workspace
        adopted.folderPath = url.path
        try layDownSkeleton(in: url, for: adopted)
    }

    func writeManifest(for workspace: JobWorkspace) throws {
        let folderURL = workspace.folderURL
        guard fileManager.fileExists(atPath: folderURL.path) else {
            throw WorkspaceFolderError.folderMissing(folderURL.path)
        }
        try WorkspaceManifest(workspace: workspace).write(to: folderURL)
    }

    // MARK: - Internals

    private func layDownSkeleton(in folderURL: URL, for workspace: JobWorkspace) throws {
        for category in WorkspaceFolderLayout.provisionedCategories {
            let subfolder = folderURL.appendingPathComponent(category.folderName, isDirectory: true)
            if !fileManager.fileExists(atPath: subfolder.path) {
                try fileManager.createDirectory(at: subfolder, withIntermediateDirectories: true)
            }
        }
        let readmeURL = folderURL.appendingPathComponent(WorkspaceFolderLayout.readmeFileName)
        if !fileManager.fileExists(atPath: readmeURL.path) {
            try WorkspaceFolderLayout.readmeContents(for: workspace).write(to: readmeURL, atomically: true, encoding: .utf8)
        }
        try WorkspaceManifest(workspace: workspace).write(to: folderURL)
    }

    private func uniqueFolderURL(for workspace: JobWorkspace) -> URL {
        let base = WorkspaceFolderLayout.folderName(for: workspace)
        var candidate = rootDirectory.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = rootDirectory.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }
}
