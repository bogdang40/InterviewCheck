import Foundation

// MARK: - Protocol

protocol DebriefEvidencePackaging {
    func package(
        sessionId: String,
        transcriptEntries: [TranscriptEntryRecord],
        quickAssistCalls: [QuickAssistCallRecord],
        coachFindings: [CoachFindingRecord],
        responseCardEvents: [WorkstreamTimelineEvent],
        existingDebriefId: String?
    ) -> DebriefContext?
}

// MARK: - Implementation

struct DebriefEvidencePackager: DebriefEvidencePackaging {

    private let transcriptWordFloor = 150
    private let condensationThreshold = 2000
    private let headTailSize = 500

    func package(
        sessionId: String,
        transcriptEntries: [TranscriptEntryRecord],
        quickAssistCalls: [QuickAssistCallRecord],
        coachFindings: [CoachFindingRecord],
        responseCardEvents: [WorkstreamTimelineEvent],
        existingDebriefId: String?
    ) -> DebriefContext? {
        let wordCount = transcriptEntries.reduce(0) { $0 + $1.text.split(separator: " ").count }

        guard wordCount >= transcriptWordFloor || !quickAssistCalls.isEmpty else {
            return nil
        }

        let condensed = condenseTranscript(entries: transcriptEntries, wordCount: wordCount)
        let qaManifest = buildQuickAssistManifest(calls: quickAssistCalls)
        let coachManifest = buildCoachFindingsManifest(findings: coachFindings)
        let cardSummary = buildResponseCardSummary(events: responseCardEvents)
        let metrics = computeMetrics(
            calls: quickAssistCalls,
            findings: coachFindings,
            cardEvents: responseCardEvents
        )

        return DebriefContext(
            sessionId: sessionId,
            condensedTranscript: condensed,
            transcriptWordCount: wordCount,
            transcriptEntryCount: transcriptEntries.count,
            quickAssistManifest: qaManifest,
            coachFindingsManifest: coachManifest,
            responseCardSummary: cardSummary,
            metrics: metrics,
            existingDebriefId: existingDebriefId
        )
    }

    // MARK: - Transcript Condensation

    private func condenseTranscript(entries: [TranscriptEntryRecord], wordCount: Int) -> String {
        let fullText = entries.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")

        guard wordCount > condensationThreshold else {
            return fullText
        }

        let words = fullText.split(separator: " ", omittingEmptySubsequences: false)
        let headWords = words.prefix(headTailSize)
        let tailWords = words.suffix(headTailSize)
        let omitted = words.count - headTailSize * 2

        return headWords.joined(separator: " ")
            + "\n\n[... \(omitted) words omitted for brevity ...]\n\n"
            + tailWords.joined(separator: " ")
    }

    // MARK: - Quick Assist Manifest

    private func buildQuickAssistManifest(calls: [QuickAssistCallRecord]) -> String {
        guard !calls.isEmpty else { return "No Quick Assist calls recorded." }

        let sorted = calls.sorted { score(for: $0) > score(for: $1) }
        let lines = sorted.prefix(20).enumerated().map { index, call in
            let question = call.question ?? "(no question)"
            let latency = call.durationMs.map { "\($0)ms" } ?? "n/a"
            let claims = call.unsupportedClaimCount ?? 0
            return "Turn \(index + 1): verification=\(call.verificationStatus.rawValue), "
                + "latency=\(latency), unsupported_claims=\(claims), "
                + "question=\"\(question.prefix(120))\""
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Coach Findings Manifest

    private func buildCoachFindingsManifest(findings: [CoachFindingRecord]) -> String {
        guard !findings.isEmpty else { return "No coach findings raised." }

        let lines = findings.map { finding in
            let evidence = finding.evidence.map { "\($0.label)=\($0.value)" }.joined(separator: ", ")
            return "[\(finding.issueType.rawValue)] \(finding.severity.rawValue): "
                + "\(finding.title) | \(finding.message)"
                + (evidence.isEmpty ? "" : " | evidence: \(evidence)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Response Card Summary

    private func buildResponseCardSummary(events: [WorkstreamTimelineEvent]) -> String {
        guard !events.isEmpty else { return "No live response cards captured." }
        return "\(events.count) response cards fired. "
            + "Latest: \(events.last?.title ?? "n/a")"
    }

    // MARK: - Metrics

    func computeMetrics(
        calls: [QuickAssistCallRecord],
        findings: [CoachFindingRecord],
        cardEvents: [WorkstreamTimelineEvent]
    ) -> DebriefMetrics {
        let successful = calls.filter { $0.status == "success" }
        let failed = calls.filter { $0.status == "error" }
        let verified = calls.filter { $0.verificationStatus == .verified }
        let latencies = successful.compactMap(\.durationMs)
        let avgLatency = latencies.isEmpty ? nil : latencies.reduce(0, +) / latencies.count
        let claimTotal = calls.reduce(0) { $0 + max(0, $1.unsupportedClaimCount ?? 0) }

        return DebriefMetrics(
            totalQuickAssistCalls: calls.count,
            successfulCalls: successful.count,
            failedCalls: failed.count,
            verifiedCalls: verified.count,
            averageLatencyMs: avgLatency,
            coachFindingCount: findings.count,
            responseCardCount: cardEvents.count,
            unsupportedClaimTotal: claimTotal
        )
    }

    // MARK: - Scoring

    private func score(for call: QuickAssistCallRecord) -> Double {
        let statusScore: Double
        switch call.verificationStatus {
        case .verified: statusScore = 4
        case .needsReview: statusScore = 2
        case .pending: statusScore = 1
        case .failed: statusScore = 0
        }
        return statusScore - Double(max(0, call.unsupportedClaimCount ?? 0)) * 0.5
    }
}
