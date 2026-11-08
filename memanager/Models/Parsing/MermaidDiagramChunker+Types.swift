import Foundation

extension MermaidDiagramChunker {
    struct Metrics: Equatable {
        let characterCount: Int
        let lineCount: Int
        let nonEmptyLineCount: Int
        let longestLineLength: Int
        let averageNonEmptyLineLength: Int
        let edgeLineCount: Int
    }

    struct Chunk: Equatable, Identifiable {
        let index: Int
        let total: Int
        let title: String
        let diagram: String
        let metrics: Metrics

        var id: String {
            "mermaid-chunk-\(index + 1)-of-\(total)"
        }
    }

    struct Result: Equatable {
        let metrics: Metrics
        let chunks: [Chunk]
        let reason: String

        var didSplit: Bool {
            chunks.count > 1
        }
    }

    enum SplitProfile: Equatable {
        case standard
        case quickAssistAggressive

        var maxNonEmptyLinesBeforeSplit: Int {
            switch self {
            case .standard: return 28
            case .quickAssistAggressive: return 20
            }
        }

        var maxCharactersBeforeSplit: Int {
            switch self {
            case .standard: return 1_850
            case .quickAssistAggressive: return 1_250
            }
        }

        var maxEdgeLinesBeforeSplit: Int {
            switch self {
            case .standard: return 22
            case .quickAssistAggressive: return 12
            }
        }

        var targetEdgesPerChunk: Int {
            switch self {
            case .standard: return 14
            case .quickAssistAggressive: return 8
            }
        }

        var maxCharactersPerChunk: Int {
            switch self {
            case .standard: return 1_400
            case .quickAssistAggressive: return 900
            }
        }

        var allowsSubgraphBlocks: Bool {
            switch self {
            case .standard:
                return false
            case .quickAssistAggressive:
                return true
            }
        }
    }

}
