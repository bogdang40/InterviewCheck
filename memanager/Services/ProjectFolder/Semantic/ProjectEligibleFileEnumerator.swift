import Foundation

enum ProjectEligibleFileError: Error, LocalizedError {
    case directory(path: String)
    case sensitive(path: String)
    case tooLarge(path: String, size: Int, maxBytes: Int)
    case unreadable(path: String)
    case binary(path: String)
    case undecodable(path: String)

    var errorDescription: String? {
        switch self {
        case .directory(let path):
            return "Expected a file but found a directory at \(path)."
        case .sensitive:
            return "File denied by policy: secrets are not accessible."
        case .tooLarge(let path, let size, let maxBytes):
            return "File too large (\(path), \(size) bytes > cap \(maxBytes))."
        case .unreadable:
            return "Could not read file."
        case .binary:
            return "File appears to be binary."
        case .undecodable:
            return "File could not be decoded as UTF 8."
        }
    }
}

final class ProjectEligibleFileEnumerator {
    private let context: ProjectToolContext
    private let fileManager = FileManager.default

    init(context: ProjectToolContext) {
        self.context = context
    }

    func resolveScope(_ subpath: String?) throws -> URL {
        try context.access.canonicalize(relativePath: subpath ?? "", rootURL: context.rootURL)
    }

    func loadTextFile(relativePath: String) throws -> ProjectTextFile {
        if isSensitive(relativePath) {
            throw ProjectEligibleFileError.sensitive(path: relativePath)
        }

        let url = try context.access.canonicalize(relativePath: relativePath, rootURL: context.rootURL)
        let file = try metadata(for: url)
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw ProjectEligibleFileError.unreadable(path: relativePath)
        }
        if file.size > context.config.maxFileSizeBytes {
            throw ProjectEligibleFileError.tooLarge(
                path: relativePath,
                size: file.size,
                maxBytes: context.config.maxFileSizeBytes
            )
        }
        guard let data = try? Data(contentsOf: url) else {
            throw ProjectEligibleFileError.unreadable(path: relativePath)
        }
        if data.prefix(8192).contains(0) {
            throw ProjectEligibleFileError.binary(path: relativePath)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ProjectEligibleFileError.undecodable(path: relativePath)
        }
        return ProjectTextFile(
            relativePath: file.relativePath,
            url: file.url,
            text: text,
            lines: text.components(separatedBy: "\n"),
            size: file.size
        )
    }

    func enumerateFiles(in subpath: String? = nil, body: (ProjectEligibleFile) throws -> Bool) throws {
        let scopeURL = try resolveScope(subpath)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: scopeURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if context.access.isExcluded(name: name, patterns: context.config.excludePatterns) {
                enumerator.skipDescendants()
                continue
            }
            guard let file = try metadataIfEligible(for: url) else {
                continue
            }
            let shouldContinue = try body(file)
            if !shouldContinue {
                break
            }
        }
    }

    private func metadataIfEligible(for url: URL) throws -> ProjectEligibleFile? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        if values?.isDirectory == true {
            return nil
        }

        let relativePath = relativePath(for: url)
        if isSensitive(relativePath) {
            return nil
        }

        let size = values?.fileSize ?? 0
        if size > context.config.maxFileSizeBytes {
            return nil
        }

        return ProjectEligibleFile(
            relativePath: relativePath,
            url: url,
            size: size,
            modifiedAt: values?.contentModificationDate ?? .distantPast,
            fileExtension: url.pathExtension.lowercased()
        )
    }

    private func metadata(for url: URL) throws -> ProjectEligibleFile {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        if values.isDirectory == true {
            throw ProjectEligibleFileError.directory(path: relativePath(for: url))
        }
        return ProjectEligibleFile(
            relativePath: relativePath(for: url),
            url: url,
            size: values.fileSize ?? 0,
            modifiedAt: values.contentModificationDate ?? .distantPast,
            fileExtension: url.pathExtension.lowercased()
        )
    }

    private func relativePath(for url: URL) -> String {
        if let relativePath = relativePath(from: url, to: context.rootURL) {
            return relativePath
        }
        return url.lastPathComponent
    }

    private func relativePath(from fileURL: URL, to rootURL: URL) -> String? {
        let candidates = [
            fileURL.standardizedFileURL,
            fileURL.resolvingSymlinksInPath().standardizedFileURL
        ]
        let roots = [
            rootURL.standardizedFileURL,
            rootURL.resolvingSymlinksInPath().standardizedFileURL
        ]

        for candidate in candidates {
            for root in roots {
                let candidateComponents = candidate.pathComponents
                let rootComponents = root.pathComponents
                guard candidateComponents.starts(with: rootComponents) else { continue }

                let relativeComponents = candidateComponents.dropFirst(rootComponents.count)
                return relativeComponents.joined(separator: "/")
            }
        }

        return nil
    }

    private func isSensitive(_ relativePath: String) -> Bool {
        !context.config.allowSensitiveReads && ProjectToolHelpers.isSensitivePath(relativePath)
    }
}
