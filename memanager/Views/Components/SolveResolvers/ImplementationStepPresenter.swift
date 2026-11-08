import Foundation

/// Where the teleprompter cursor sits inside the expanded step.
struct TeleprompterProgress: Equatable {
    let current: Int
    let total: Int
}

/// Captions for the step list, kept pure so the wording can be tested.
enum ImplementationStepPresenter {
    static func caption(current: Int, total: Int) -> String {
        guard total > 0 else { return "No steps yet" }
        let clamped = min(max(current, 1), total)
        return "Step \(clamped) of \(total)"
    }

    static func preview(of step: ImplementationStep) -> String? {
        SpeakableChunkSplitter.preview(of: step.reasoning)
    }

    static func teleprompterCaption(_ progress: TeleprompterProgress) -> String {
        guard progress.total > 0 else { return "Ready" }
        let clamped = min(max(progress.current + 1, 1), progress.total)
        return "\(clamped) of \(progress.total)"
    }

    static func lineCount(of code: String) -> Int {
        guard !code.isEmpty else { return 0 }
        return code.components(separatedBy: "\n").count
    }
}
