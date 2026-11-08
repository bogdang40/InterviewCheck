import Foundation

final class WorkstreamTimelineComposer {
    func buildThreadMetrics(
        summary: QuickAssistThreadSummary,
        calls: [QuickAssistCallRecord]
    ) -> WorkstreamThreadMetrics {
        let successCalls = calls.filter { $0.status == "success" }
        let errorCount = calls.filter { $0.status == "error" }.count
        let durationValues = successCalls.compactMap(\.durationMs)
        let averageDurationMs: Int? = durationValues.isEmpty
            ? nil
            : (durationValues.reduce(0, +) / durationValues.count)
        let latestResponseSnippet = successCalls.last?.responseText.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
        }
        var contextMix: [QuickAssistContextMode: Int] = [:]
        for call in successCalls {
            contextMix[call.contextMode, default: 0] += 1
        }

        return WorkstreamThreadMetrics(
            threadId: summary.id,
            title: summary.title,
            turnCount: successCalls.count,
            successCount: successCalls.count,
            errorCount: errorCount,
            averageDurationMs: averageDurationMs,
            latestResponseSnippet: latestResponseSnippet,
            contextModeMix: contextMix
        )
    }

    func compareThreads(
        left: WorkstreamThreadMetrics,
        right: WorkstreamThreadMetrics
    ) -> WorkstreamThreadComparison {
        var highlights: [String] = []

        if left.turnCount != right.turnCount {
            let winner = left.turnCount > right.turnCount ? left.title : right.title
            highlights.append("\(winner) has more successful turns.")
        }

        switch (left.averageDurationMs, right.averageDurationMs) {
        case let (.some(l), .some(r)):
            if l != r {
                let faster = l < r ? left.title : right.title
                highlights.append("\(faster) is faster on average.")
            }
        default:
            break
        }

        if left.errorCount != right.errorCount {
            let safer = left.errorCount < right.errorCount ? left.title : right.title
            highlights.append("\(safer) has fewer failed turns.")
        }

        if highlights.isEmpty {
            highlights.append("Both threads are similar on current metrics.")
        }

        return WorkstreamThreadComparison(
            left: left,
            right: right,
            highlights: highlights
        )
    }
}
