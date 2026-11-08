import Foundation

/// Spawns `rg`, collects stdout and stderr, returns typed matches or file hits.
///
/// The service never resolves user supplied paths. Callers must pass a `scope`
/// URL that has already been canonicalized by `ProjectFolderAccess`. The child
/// process is started with its working directory set to `scope` so every path
/// in the output is already relative to the sandboxed root.
final class RipgrepService {
    static let shared = RipgrepService()

    struct SearchOptions {
        var pattern: String
        var scope: URL
        var caseSensitive: Bool = false
        var fixedStrings: Bool = false
        var multiline: Bool = false
        var contextBefore: Int = 0
        var contextAfter: Int = 0
        var fileTypes: [String] = []
        var includeHidden: Bool = false
        var respectGitignore: Bool = true
        var maxCount: Int = 200
        var maxFileSizeBytes: Int = 2 * 1024 * 1024
    }

    struct FileListOptions {
        var scope: URL
        var pattern: String? = nil
        var fileTypes: [String] = []
        var includeHidden: Bool = false
        var respectGitignore: Bool = true
    }

    private let locator: RipgrepBinaryLocator

    init(locator: RipgrepBinaryLocator = .shared) {
        self.locator = locator
    }

    func search(_ opts: SearchOptions) async throws -> [RipgrepMatch] {
        guard let binary = locator.locate() else { throw RipgrepError.binaryNotFound }
        let args = RipgrepArgBuilder.searchArgs(opts)
        let result = try await RipgrepProcessRunner.run(binary: binary, args: args, cwd: opts.scope)
        if result.exitCode != 0 && result.exitCode != 1 {
            throw RipgrepError.nonZeroExit(result.exitCode, result.stderr)
        }
        return RipgrepJSONDecoder.decodeMatches(result.stdout)
    }

    func files(_ opts: FileListOptions) async throws -> [RipgrepFileHit] {
        guard let binary = locator.locate() else { throw RipgrepError.binaryNotFound }
        let args = RipgrepArgBuilder.filesArgs(opts)
        let result = try await RipgrepProcessRunner.run(binary: binary, args: args, cwd: opts.scope)
        if result.exitCode != 0 {
            throw RipgrepError.nonZeroExit(result.exitCode, result.stderr)
        }
        return RipgrepJSONDecoder.decodeFiles(result.stdout).map { RipgrepFileHit(relativePath: $0, modifiedAt: nil) }
    }
}
