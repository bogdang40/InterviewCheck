import CryptoKit
import Foundation

struct WorkspaceIndexReport: Equatable {
    var scanned = 0
    var updated = 0
    var removed = 0
    var skipped = 0
    var failures: [String] = []

    var summary: String {
        "\(scanned) files, \(updated) updated, \(removed) removed" + (failures.isEmpty ? "" : ", \(failures.count) failed")
    }
}

/// Walks a workspace folder and keeps `workspace_documents` in step with it.
/// Unchanged files (same size and SHA-256) are not re-extracted, so a
/// re-index after one edit costs one extraction.
final class WorkspaceDocumentIndexer {
    private let database: SessionDatabase
    private let extractor: ModeTextExtracting
    private let fileManager: FileManager

    init(
        database: SessionDatabase = .shared,
        extractor: ModeTextExtracting = DefaultModeTextExtractor.shared,
        fileManager: FileManager = .default
    ) {
        self.database = database
        self.extractor = extractor
        self.fileManager = fileManager
    }

    @discardableResult
    func index(_ workspace: JobWorkspace, now: Date = Date(), verifyContents: Bool = false) -> WorkspaceIndexReport {
        var report = WorkspaceIndexReport()
        let root = workspace.folderURL
        guard fileManager.fileExists(atPath: root.path) else {
            report.failures.append("Folder missing: \(root.path)")
            return report
        }
        let existing = Dictionary(uniqueKeysWithValues: database.loadWorkspaceDocuments(workspaceID: workspace.id).map { ($0.relativePath, $0) })
        var seenPaths = Set<String>()

        let enumeration = enumerateFiles(under: root)
        report.failures.append(contentsOf: enumeration.failures)
        if enumeration.truncated {
            report.failures.append("Stopped after \(WorkspaceFolderLayout.maxIndexedFiles) files; move large trees out of the workspace folder")
        }
        for fileURL in enumeration.files {
            let relativePath = WorkspaceDocumentIndexer.relativePath(of: fileURL, under: root)
            seenPaths.insert(relativePath)
            report.scanned += 1
            do {
                if let document = try indexFile(fileURL, relativePath: relativePath, workspace: workspace,
                                                existing: existing[relativePath], now: now, verifyContents: verifyContents) {
                    try database.upsertWorkspaceDocument(document)
                    report.updated += 1
                } else {
                    report.skipped += 1
                }
            } catch {
                report.failures.append("\(relativePath): \(error.localizedDescription)")
            }
        }

        // Past the cap the walk is partial, so an unseen row may still be on
        // disk; only remove rows whose file is really gone.
        let vanished = existing.keys.filter { relativePath in
            // Permission and enumeration failures do not prove that a file
            // disappeared. Preserve the last index until a complete scan.
            guard enumeration.failures.isEmpty else { return false }
            guard !seenPaths.contains(relativePath) else { return false }
            return !enumeration.truncated || !fileManager.fileExists(atPath: root.appendingPathComponent(relativePath).path)
        }
        if !vanished.isEmpty {
            do {
                try database.deleteWorkspaceDocuments(workspaceID: workspace.id, relativePaths: vanished)
                report.removed = vanished.count
            } catch {
                report.failures.append("Could not remove missing documents: \(error.localizedDescription)")
            }
        }
        return report
    }

    // MARK: - Per file

    /// Returns nil when the stored row already matches the file on disk.
    private func indexFile(
        _ fileURL: URL,
        relativePath: String,
        workspace: JobWorkspace,
        existing: WorkspaceDocument?,
        now: Date,
        verifyContents: Bool
    ) throws -> WorkspaceDocument? {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let byteSize = (attributes[.size] as? Int) ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date) ?? now
        let kind = WorkspaceDocumentKind(pathExtension: fileURL.pathExtension)
        let canExtract = kind.isTextBearing && byteSize <= WorkspaceFolderLayout.maxExtractableBytes
        let needsExtraction = canExtract && existing?.extractedText == nil

        // Stored dates are millisecond precision; file dates carry nanoseconds.
        if let existing, !verifyContents, !needsExtraction, existing.byteSize == byteSize,
           abs(existing.modifiedAt.timeIntervalSince(modifiedAt)) < 0.002 {
            return nil
        }
        let digest = byteSize > WorkspaceFolderLayout.maxHashedBytes
            ? "size:\(byteSize)"
            : try WorkspaceDocumentIndexer.sha256(of: fileURL)
        if let existing, existing.sha256 == digest, !needsExtraction {
            var refreshed = existing
            refreshed.modifiedAt = modifiedAt
            refreshed.indexedAt = now
            return refreshed
        }

        var extracted: ExtractedText?
        if canExtract, let attachmentKind = kind.attachmentKind {
            extracted = try extractor.extract(from: fileURL, kind: attachmentKind)
        }
        return WorkspaceDocument(
            id: existing?.id ?? UUID(),
            workspaceID: workspace.id,
            relativePath: relativePath,
            kind: kind,
            category: WorkspaceFolderLayout.category(forRelativePath: relativePath),
            byteSize: byteSize,
            sha256: digest,
            extractedText: extracted?.raw.trimmingCharacters(in: .whitespacesAndNewlines),
            extractedTruncated: extracted?.truncated ?? false,
            indexedAt: now,
            modifiedAt: modifiedAt
        )
    }

    /// Regular files under `root`, minus dependency trees, the root manifest
    /// and README, and .DS_Store. Returns whether the file cap was hit.
    private struct FileEnumeration {
        var files: [URL] = []
        var truncated = false
        var failures: [String] = []
    }

    private func enumerateFiles(under root: URL) -> FileEnumeration {
        var result = FileEnumeration()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                result.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                return true
            }
        ) else {
            result.failures.append("Could not enumerate folder: \(root.path)")
            return result
        }
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                result.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            if values.isDirectory == true {
                if WorkspaceFolderLayout.skippedDirectoryNames.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, url.lastPathComponent != ".DS_Store" else { continue }
            let relativePath = WorkspaceDocumentIndexer.relativePath(of: url, under: root)
            if WorkspaceFolderLayout.rootMetadataFileNames.contains(relativePath) { continue }
            result.files.append(url)
            if result.files.count >= WorkspaceFolderLayout.maxIndexedFiles {
                result.truncated = true
                break
            }
        }
        result.files.sort { $0.path < $1.path }
        return result
    }

    static func relativePath(of fileURL: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let filePath = fileURL.standardizedFileURL.path
        return filePath.hasPrefix(rootPath) ? String(filePath.dropFirst(rootPath.count)) : fileURL.lastPathComponent
    }

    static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
