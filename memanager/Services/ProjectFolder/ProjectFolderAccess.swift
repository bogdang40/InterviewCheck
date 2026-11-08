import Foundation

/// Safely resolves a `ProjectFolderConfig` into a sandboxed root URL and enforces path
/// canonicalization. Every tool call passes paths through `canonicalize` which rejects absolute
/// paths, parent traversal, and any path whose symlink resolution escapes the root.
enum ProjectFolderAccessError: Error, LocalizedError {
    case bookmarkMissing
    case bookmarkStale
    case resolveFailed(Error)
    case accessDenied
    case absolutePath
    case parentTraversal
    case outOfSandbox
    case notReadable(Error)

    var errorDescription: String? {
        switch self {
        case .bookmarkMissing: return "No folder has been selected for this Mode."
        case .bookmarkStale: return "The folder bookmark is stale. Please reselect the folder."
        case .resolveFailed(let e): return "Could not resolve folder: \(e.localizedDescription)"
        case .accessDenied: return "Access to the folder was denied."
        case .absolutePath: return "Absolute paths are not allowed; use paths relative to the project root."
        case .parentTraversal: return "Path contains '..' which is not permitted."
        case .outOfSandbox: return "Path resolves outside the project root and is refused."
        case .notReadable(let e): return "File is not readable: \(e.localizedDescription)"
        }
    }
}

/// Resolved, sandbox scoped URL. All tool calls operate relative to `rootURL`.
struct ResolvedProjectFolder {
    let rootURL: URL
    let didStartAccess: Bool

    func release() {
        if didStartAccess {
            rootURL.stopAccessingSecurityScopedResource()
        }
    }
}

final class ProjectFolderAccess {
    static let shared = ProjectFolderAccess()

    private init() {}

    /// Resolve the bookmark into a URL and start security scoped access. Caller must call
    /// `release()` on the returned value when done, typically via a `defer`.
    func resolve(config: ProjectFolderConfig) throws -> ResolvedProjectFolder {
        guard let bookmark = config.bookmarkData else {
            throw ProjectFolderAccessError.bookmarkMissing
        }
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw ProjectFolderAccessError.resolveFailed(error)
        }
        if isStale {
            throw ProjectFolderAccessError.bookmarkStale
        }
        let didStart = url.startAccessingSecurityScopedResource()
        guard didStart else {
            throw ProjectFolderAccessError.accessDenied
        }
        return ResolvedProjectFolder(rootURL: url, didStartAccess: didStart)
    }

    /// Canonicalize a relative path against the root. Returns an absolute file URL inside the
    /// root. Rejects absolute paths, `..` segments, and symlinks that escape the root.
    func canonicalize(relativePath: String, rootURL: URL) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return rootURL.standardizedFileURL }
        if trimmed.hasPrefix("/") {
            throw ProjectFolderAccessError.absolutePath
        }
        if trimmed.split(separator: "/").contains("..") {
            throw ProjectFolderAccessError.parentTraversal
        }
        let candidate = rootURL.appendingPathComponent(trimmed).standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        let resolvedRoot = rootURL.resolvingSymlinksInPath()
        let candidatePath = resolvedCandidate.path
        let rootPath = resolvedRoot.path
        if candidatePath == rootPath { return resolvedCandidate }
        if !candidatePath.hasPrefix(rootPath + "/") {
            throw ProjectFolderAccessError.outOfSandbox
        }
        return resolvedCandidate
    }

    /// Rebases search results to the selected project root for follow-up tool calls.
    func rootRelativePath(_ relativePath: String, scopeURL: URL, rootURL: URL) throws -> String {
        let candidate = try canonicalize(relativePath: relativePath, rootURL: scopeURL)
        let root = rootURL.resolvingSymlinksInPath().path
        let path = candidate.resolvingSymlinksInPath().path
        guard path.hasPrefix(root + "/") else {
            throw ProjectFolderAccessError.outOfSandbox
        }
        return String(path.dropFirst(root.count + 1))
    }

    /// Quick check whether a directory name matches an exclude pattern (simple literal match).
    func isExcluded(name: String, patterns: [String]) -> Bool {
        patterns.contains(name)
    }
}
