import Foundation
import CryptoKit

/// Memoized derivations of mermaid diagram text.
///
/// SwiftUI re-inits representable structs on every parent body pass, and the
/// chunk splitting heuristics, sanitizer, retry repair, and MD5 identity all
/// ran inside those inits with their results discarded. Content keyed caches
/// make re-init effectively free.
enum MermaidContentCaches {
    struct SanitizedDiagram {
        let sanitized: String
        let retry: String
        let diagramId: String
    }

    private static let chunkingCache = MemoizedParse<MermaidDiagramChunker.Result>(capacity: 8)
    private static let sanitizedCache = MemoizedParse<SanitizedDiagram>(capacity: 8)

    static func chunkingResult(
        diagram: String,
        profile: MermaidDiagramChunker.SplitProfile
    ) -> MermaidDiagramChunker.Result {
        chunkingCache.value(for: "\(String(describing: profile))|\(diagram)") { _ in
            MermaidDiagramChunker.split(diagram: diagram, profile: profile)
        }
    }

    static func sanitizedContent(for diagram: String) -> SanitizedDiagram {
        sanitizedCache.value(for: diagram) { text in
            let hash = Insecure.MD5.hash(data: Data(text.utf8))
            return SanitizedDiagram(
                sanitized: MermaidSanitizer.sanitizeMermaid(text),
                retry: MermaidSanitizer.repairMermaidForRetry(text),
                diagramId: "mermaid-\(hash.prefix(4).map { String(format: "%02x", $0) }.joined())"
            )
        }
    }
}
