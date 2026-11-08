import Foundation

/// Decides whether a folder the user picked is safe to adopt as a workspace
/// and which identity it should carry. Pure, so the rules are testable.
enum WorkspaceImportGuard {
    enum Refusal: Error, LocalizedError, Equatable {
        case tooBroad(String)

        var errorDescription: String? {
            switch self {
            case .tooBroad(let path):
                return "\(path) is too broad to be a workspace. Pick or create a folder dedicated to one job."
            }
        }
    }

    /// Folders that hold a person's whole life rather than one job.
    static let broadUserDirectories: [FileManager.SearchPathDirectory] = [
        .documentDirectory, .desktopDirectory, .downloadsDirectory, .moviesDirectory,
        .musicDirectory, .picturesDirectory, .libraryDirectory, .applicationDirectory,
    ]

    /// A path this shallow (the volume root, /Users, /Users/name) is never a
    /// workspace, whatever it is called.
    static let minimumPathComponents = 4

    /// Refuses the home folder, the standard user folders, the workspaces
    /// root itself, and anything above the home folder.
    static func validate(_ url: URL, rootDirectory: URL, fileManager: FileManager = .default) throws {
        let standardized = url.standardizedFileURL
        let candidate = standardized.path
        var forbidden = [
            fileManager.homeDirectoryForCurrentUser,
            rootDirectory,
        ]
        for directory in broadUserDirectories {
            if let folder = fileManager.urls(for: directory, in: .userDomainMask).first {
                forbidden.append(folder)
            }
        }
        if forbidden.contains(where: { $0.standardizedFileURL.path == candidate }) {
            throw Refusal.tooBroad(url.path)
        }
        if standardized.pathComponents.count < minimumPathComponents {
            throw Refusal.tooBroad(url.path)
        }
    }

    /// A manifest may only re-point an existing workspace when the old
    /// folder is gone (it was moved) or it is the same folder. Otherwise a
    /// copied manifest would hijack another workspace's identity.
    static func shouldAdoptExistingIdentity(existingFolderPath: String, importedFolderPath: String, fileManager: FileManager = .default) -> Bool {
        if existingFolderPath == importedFolderPath { return true }
        return !fileManager.fileExists(atPath: existingFolderPath)
    }
}
