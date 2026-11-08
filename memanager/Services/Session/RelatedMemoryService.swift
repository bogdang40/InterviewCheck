import Foundation

protocol RelatedMemoryRetrieving {
    func retrieve(query: RelatedMemoryQuery, limit: Int) -> RelatedMemoryResult
}

final class RelatedMemoryService: RelatedMemoryRetrieving {
    private let logger: SessionLogger

    init(logger: SessionLogger = .shared) {
        self.logger = logger
    }

    func retrieve(query: RelatedMemoryQuery, limit: Int) -> RelatedMemoryResult {
        logger.searchHubMemory(query: query, limit: limit)
    }
}

enum RelatedMemoryRefreshTrigger {
    case threadNavigation
    case turnSelection
    case quickAssistView

    var querySource: RelatedMemoryQuerySource {
        switch self {
        case .threadNavigation:
            return .threadNavigation
        case .turnSelection:
            return .turnSelection
        case .quickAssistView:
            return .quickAssistView
        }
    }
}
