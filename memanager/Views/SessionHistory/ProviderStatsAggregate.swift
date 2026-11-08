import Foundation

/// Totals for one provider across the 30 day provider stats window.
struct ProviderStatsAggregate: Identifiable, Equatable {
    let provider: String
    let calls: Int
    let successes: Int
    let errors: Int
    let totalDurationMs: Int

    var id: String { provider }

    var averageDurationMs: Double {
        guard successes > 0 else { return 0 }
        return Double(totalDurationMs) / Double(successes)
    }

    var successRate: Double {
        guard calls > 0 else { return 0 }
        return Double(successes) / Double(calls) * 100
    }

    static func grouped(_ stats: [ProviderStatsRecord]) -> [ProviderStatsAggregate] {
        Dictionary(grouping: stats, by: \.provider)
            .map { provider, records in
                ProviderStatsAggregate(
                    provider: provider,
                    calls: records.reduce(0) { $0 + $1.callCount },
                    successes: records.reduce(0) { $0 + $1.successCount },
                    errors: records.reduce(0) { $0 + $1.errorCount },
                    totalDurationMs: records.reduce(0) { $0 + $1.totalDurationMs }
                )
            }
            .sorted { $0.provider < $1.provider }
    }
}

/// Relative bar lengths for the per session provider comparison.
struct ProviderComparisonScale {
    let providers: [ProviderSessionSummary]

    func successFraction(_ provider: ProviderSessionSummary) -> Double {
        min(max(provider.successRate / 100, 0), 1)
    }

    /// Latency relative to the slowest provider in the set.
    func latencyFraction(_ provider: ProviderSessionSummary) -> Double {
        guard let ms = provider.averageLatencyMs,
              let maxMs = providers.compactMap(\.averageLatencyMs).max(),
              maxMs > 0 else { return 0 }
        return Double(ms) / Double(maxMs)
    }
}
