import Foundation

// MARK: - Protocol

protocol SkillProgressionTracking {
    func buildReport(currentSessionId: String) -> SkillProgressionReport
}

// MARK: - Implementation

/// Aggregates last N sessions into snapshots, detects trends via simple
/// linear regression, and identifies recurring weak spots.
final class SkillProgressionTracker: SkillProgressionTracking {

    private let logger: SessionLogger
    private let windowSize: Int

    init(logger: SessionLogger = .shared, windowSize: Int = 5) {
        self.logger = logger
        self.windowSize = windowSize
    }

    func buildReport(currentSessionId: String) -> SkillProgressionReport {
        let sessions = logger.getRecentSessions(limit: windowSize + 1)
            .filter { $0.id != currentSessionId }
            .prefix(windowSize)

        guard sessions.count >= 2 else { return .empty }

        let snapshots = Array(sessions).compactMap { session -> SkillSnapshot? in
            buildSnapshot(sessionId: session.id, sessionDate: session.startedAt)
        }

        guard snapshots.count >= 2 else { return .empty }

        let trends = computeTrends(snapshots: snapshots)
        let weakSpots = detectRecurringWeakSpots(snapshots: snapshots)
        let promptBlock = buildPromptBlock(trends: trends, weakSpots: weakSpots)

        return SkillProgressionReport(
            snapshots: snapshots,
            trends: trends,
            recurringWeakSpots: weakSpots,
            promptBlock: promptBlock
        )
    }

    // MARK: - Snapshot Construction

    private func buildSnapshot(sessionId: String, sessionDate: Date) -> SkillSnapshot? {
        let calls = logger.getQuickAssistCallsForSession(sessionId: sessionId, limit: 500)
        guard !calls.isEmpty else { return nil }

        let successful = calls.filter { $0.status == "success" }
        let verified = calls.filter { $0.verificationStatus == .verified }
        let verificationRate = successful.isEmpty ? 0 : Double(verified.count) / Double(successful.count)

        let claimTotal = calls.reduce(0) { $0 + max(0, $1.unsupportedClaimCount ?? 0) }
        let claimDensity = Double(claimTotal) / Double(calls.count)

        let findings = logger.getCoachFindings(sessionId: sessionId)
        let findingFrequency = Double(findings.count) / Double(calls.count)

        let latencies = successful.compactMap(\.durationMs)
        let avgLatency = latencies.isEmpty ? 0 : Double(latencies.reduce(0, +)) / Double(latencies.count)

        let debrief = logger.loadSessionDebrief(sessionId: sessionId)
        let drillKinds = debrief?.drills.map(\.kind) ?? []

        return SkillSnapshot(
            sessionId: sessionId,
            sessionDate: sessionDate,
            verificationRate: verificationRate,
            unsupportedClaimDensity: claimDensity,
            coachFindingFrequency: findingFrequency,
            averageLatencyMs: avgLatency,
            drillKinds: drillKinds
        )
    }

    // MARK: - Trend Detection

    private func computeTrends(snapshots: [SkillSnapshot]) -> [SkillTrend] {
        let sorted = snapshots.sorted { $0.sessionDate < $1.sessionDate }
        let n = sorted.count

        return [
            trend(
                metric: "verification_rate",
                values: sorted.map(\.verificationRate),
                n: n,
                positiveIsGood: true
            ),
            trend(
                metric: "unsupported_claim_density",
                values: sorted.map(\.unsupportedClaimDensity),
                n: n,
                positiveIsGood: false
            ),
            trend(
                metric: "coach_finding_frequency",
                values: sorted.map(\.coachFindingFrequency),
                n: n,
                positiveIsGood: false
            ),
            trend(
                metric: "average_latency",
                values: sorted.map(\.averageLatencyMs),
                n: n,
                positiveIsGood: false
            )
        ]
    }

    private func trend(
        metric: String,
        values: [Double],
        n: Int,
        positiveIsGood: Bool
    ) -> SkillTrend {
        let slope = linearSlope(values)
        let threshold = 0.02

        let direction: SkillTrendDirection
        if abs(slope) < threshold {
            direction = .stable
        } else if (slope > 0) == positiveIsGood {
            direction = .improving
        } else {
            direction = .regressing
        }

        return SkillTrend(
            metric: metric,
            direction: direction,
            magnitude: abs(slope),
            snapshotCount: n
        )
    }

    /// Simple linear regression slope: least-squares fit of y values
    /// against indices [0, 1, 2, ...].
    private func linearSlope(_ values: [Double]) -> Double {
        let n = Double(values.count)
        guard n >= 2 else { return 0 }

        let xMean = (n - 1) / 2.0
        let yMean = values.reduce(0, +) / n

        var numerator = 0.0
        var denominator = 0.0
        for (i, y) in values.enumerated() {
            let x = Double(i)
            numerator += (x - xMean) * (y - yMean)
            denominator += (x - xMean) * (x - xMean)
        }

        guard denominator > 0 else { return 0 }
        return numerator / denominator
    }

    // MARK: - Recurring Weak Spots

    private func detectRecurringWeakSpots(snapshots: [SkillSnapshot]) -> [SessionDrillKind] {
        var kindCounts: [SessionDrillKind: Int] = [:]
        for snapshot in snapshots {
            for kind in Set(snapshot.drillKinds) {
                kindCounts[kind, default: 0] += 1
            }
        }

        let threshold = min(3, snapshots.count)
        return kindCounts
            .filter { $0.value >= threshold }
            .sorted { $0.value > $1.value }
            .map(\.key)
    }

    // MARK: - Prompt Block

    private func buildPromptBlock(trends: [SkillTrend], weakSpots: [SessionDrillKind]) -> String {
        var lines = ["## Skill Progression"]

        let regressing = trends.filter { $0.direction == .regressing }
        let improving = trends.filter { $0.direction == .improving }

        if !improving.isEmpty {
            lines.append("Improving: \(improving.map(\.metric).joined(separator: ", "))")
        }
        if !regressing.isEmpty {
            lines.append("Regressing: \(regressing.map(\.metric).joined(separator: ", "))")
        }
        if !weakSpots.isEmpty {
            lines.append("Recurring weak spots: \(weakSpots.map(\.displayLabel).joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }
}
