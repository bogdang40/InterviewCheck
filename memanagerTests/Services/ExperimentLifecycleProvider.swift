import XCTest
@testable import memanager

/// Suspends only the first request so tests can invalidate its owner before
/// delivering a result. Later requests complete without network access.
actor ExperimentLifecycleProvider: AIProvider {
    let name = "Experiment fixture"
    private let firstRequestStarted: XCTestExpectation?
    private var continuation: CheckedContinuation<String, Error>?
    private(set) var contexts: [QuickAssistContext] = []

    init(firstRequestStarted: XCTestExpectation? = nil) {
        self.firstRequestStarted = firstRequestStarted
    }

    func quickAssist(context: QuickAssistContext) async throws -> String {
        contexts.append(context)
        if contexts.count == 1, let firstRequestStarted {
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                firstRequestStarted.fulfill()
            }
        }
        return "The retained provider answer"
    }

    func finishFirst(failing: Bool = false) {
        if failing {
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(returning: "The retained provider answer")
        }
        continuation = nil
    }

    func complete(context: SessionContext) async throws -> MentorResponse { throw CancellationError() }
    func completeStreaming(context: SessionContext, onChunk: @escaping (String) -> Void) async throws -> MentorResponse {
        throw CancellationError()
    }
    func completeSystemDesign(context: SessionContext) async throws -> MentorResponse { throw CancellationError() }
    func completeSystemDesignStreaming(context: SessionContext, onChunk: @escaping (String) -> Void) async throws -> MentorResponse {
        throw CancellationError()
    }
    func quickAssistStreaming(context: QuickAssistContext, onChunk: @escaping (String) -> Void) async throws {
        throw CancellationError()
    }
    func mlGuideStreaming(context: MLGuideContext, onChunk: @escaping (String) -> Void) async throws {
        throw CancellationError()
    }
    func debrief(context: DebriefContext) async throws -> String { throw CancellationError() }
}
