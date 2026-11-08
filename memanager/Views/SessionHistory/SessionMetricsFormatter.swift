import Foundation

/// One tile of the overview ribbon.
struct SessionMetricTileModel: Identifiable, Equatable {
    let id: String
    let value: String
    let label: String
    let tone: OverlayTone
    let systemImage: String
}

/// Turns debrief metrics into the five tiles read first on the overview.
enum SessionMetricsFormatter {
    static func verifiedPercent(_ metrics: DebriefMetrics) -> String {
        guard metrics.totalQuickAssistCalls > 0 else { return "0%" }
        let percent = Int(Double(metrics.verifiedCalls) / Double(metrics.totalQuickAssistCalls) * 100)
        return "\(percent)%"
    }

    static func latency(_ metrics: DebriefMetrics) -> String {
        guard let ms = metrics.averageLatencyMs else { return "n/a" }
        return "\(ms)ms"
    }

    static func tiles(for metrics: DebriefMetrics) -> [SessionMetricTileModel] {
        [
            SessionMetricTileModel(id: "turns", value: "\(metrics.totalQuickAssistCalls)", label: "Turns", tone: .neutral, systemImage: "bubble.left.and.bubble.right"),
            SessionMetricTileModel(id: "verified", value: verifiedPercent(metrics), label: "Verified", tone: .success, systemImage: "checkmark.shield"),
            SessionMetricTileModel(id: "latency", value: latency(metrics), label: "Latency", tone: .neutral, systemImage: "timer"),
            SessionMetricTileModel(id: "coach", value: "\(metrics.coachFindingCount)", label: "Coach", tone: metrics.coachFindingCount > 0 ? .warning : .neutral, systemImage: "figure.wave"),
            SessionMetricTileModel(id: "claims", value: "\(metrics.unsupportedClaimTotal)", label: "Claims", tone: metrics.unsupportedClaimTotal > 0 ? .critical : .neutral, systemImage: "exclamationmark.bubble")
        ]
    }
}
