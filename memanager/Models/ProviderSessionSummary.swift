import Foundation

/// Per-provider aggregate metrics derived from Quick Assist calls within a single session.
struct ProviderSessionSummary: Identifiable {
    let provider: String
    let model: String?
    let callCount: Int
    let successCount: Int
    let errorCount: Int
    let averageLatencyMs: Int?

    var id: String { "\(provider)_\(model ?? "default")" }

    var successRate: Double {
        callCount > 0 ? Double(successCount) / Double(callCount) * 100 : 0
    }

    /// Builds provider summaries from a set of Quick Assist call records.
    static func from(calls: [QuickAssistCallRecord]) -> [ProviderSessionSummary] {
        let grouped = Dictionary(grouping: calls) { $0.provider ?? "unknown" }
        return grouped.map { provider, records in
            let successful = records.filter { $0.status == "success" }
            let errors = records.filter { $0.status == "error" }
            let latencies = successful.compactMap(\.durationMs)
            let avgLatency = latencies.isEmpty ? nil : latencies.reduce(0, +) / latencies.count

            return ProviderSessionSummary(
                provider: provider,
                model: records.first?.model,
                callCount: records.count,
                successCount: successful.count,
                errorCount: errors.count,
                averageLatencyMs: avgLatency
            )
        }
        .sorted { $0.callCount > $1.callCount }
    }
}
