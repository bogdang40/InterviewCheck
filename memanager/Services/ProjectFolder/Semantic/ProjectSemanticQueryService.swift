import Foundation

final class ProjectSemanticQueryService {
    static let maxOutlineRows = 200
    static let maxRelatedFiles = 20
    static let supportedLanguageNote = "Language-aware semantic parsing is available for Swift, Python, Rust, C, and C++ in v1. Other text files still support fallback outlines, related-file lookup, and batch reads."

    let enumerator: ProjectEligibleFileEnumerator
    private let textReadService: ProjectTextReadService
    let scannerRegistry: ProjectSemanticScannerRegistry
    let fallbackScanner: ProjectOutlineFallbackScanner
    let relatedHeuristics: RelatedFileHeuristics
    let maxResults: Int
    var textCache: [String: ProjectTextFile] = [:]
    var scanCache: [String: ProjectSemanticFileScan] = [:]

    init(
        context: ProjectToolContext,
        scannerRegistry: ProjectSemanticScannerRegistry = .shared,
        fallbackScanner: ProjectOutlineFallbackScanner = ProjectOutlineFallbackScanner(),
        relatedHeuristics: RelatedFileHeuristics = RelatedFileHeuristics()
    ) {
        let enumerator = ProjectEligibleFileEnumerator(context: context)
        self.enumerator = enumerator
        self.textReadService = ProjectTextReadService(enumerator: enumerator)
        self.scannerRegistry = scannerRegistry
        self.fallbackScanner = fallbackScanner
        self.relatedHeuristics = relatedHeuristics
        self.maxResults = context.config.maxSearchResults
    }

    func readSlice(path: String, offset: Int, limit: Int) throws -> ProjectLineSlice {
        try textReadService.readSlice(path: path, offset: offset, limit: limit)
    }

    func enumerateFiles(in path: String? = nil, body: (ProjectEligibleFile) throws -> Bool) throws {
        try enumerator.enumerateFiles(in: path, body: body)
    }

    func loadTextFile(_ file: ProjectEligibleFile) throws -> ProjectTextFile {
        if let cached = textCache[file.relativePath] {
            return cached
        }
        let loaded = try enumerator.loadTextFile(relativePath: file.relativePath)
        textCache[file.relativePath] = loaded
        return loaded
    }

    func scanFile(_ file: ProjectEligibleFile) throws -> ProjectSemanticFileScan? {
        if let cached = scanCache[file.relativePath] {
            return cached
        }
        guard let scanner = scannerRegistry.scanner(for: file.fileExtension) else {
            return nil
        }
        let textFile = try loadTextFile(file)
        let scan = scanner.scan(file: textFile)
        scanCache[file.relativePath] = scan
        return scan
    }

    func scanTextFile(_ file: ProjectTextFile) throws -> ProjectSemanticFileScan? {
        try scanFile(eligibleFile(for: file))
    }

    func eligibleFile(for file: ProjectTextFile) -> ProjectEligibleFile {
        ProjectEligibleFile(
            relativePath: file.relativePath,
            url: file.url,
            size: file.size,
            modifiedAt: .distantPast,
            fileExtension: file.url.pathExtension.lowercased()
        )
    }

    func symbolSort(_ lhs: ProjectSymbolMatch, _ rhs: ProjectSymbolMatch) -> Bool {
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        return lhs.line < rhs.line
    }

    func dedupe(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                ordered.append(value)
            }
        }
        return ordered
    }

    func softLoadTextFile(_ file: ProjectEligibleFile) -> ProjectTextFile? {
        try? loadTextFile(file)
    }
}
