import Foundation

extension AudioCaptureService {
    // MARK: - Diagnostics Helpers

    @MainActor
    var isStartingCaptureFlag: Bool {
        isStartingCapture
    }

    @MainActor
    var inputTapInstalled: Bool {
        isInputTapInstalled
    }

    @MainActor
    var audioEngineRunning: Bool {
        // Use cached value to avoid thread-safety issues with AVAudioEngine
        isEngineRunning
    }

    @MainActor
    var activeTranscriptionModeLabel: String {
        activeTranscriptionMode.displayName
    }

    @MainActor
    var isLegacyDeepgramMode: Bool {
        activeTranscriptionMode == .deepgramLegacy
    }

    @MainActor
    var resolvedTranscriptionModeLabel: String {
        resolveTranscriptionMode().displayName
    }

    @MainActor
    var pendingStartReasonLabel: String {
        pendingStartReason.displayName
    }

    @MainActor
    var deepgramSystemSentChunkCount: Int {
        dualStreamService?.metricsSnapshot.system.sentChunkCount ?? 0
    }

    @MainActor
    var deepgramSystemInboundMessageCount: Int {
        dualStreamService?.metricsSnapshot.system.inboundMessageCount ?? 0
    }

    @MainActor
    var deepgramSystemTranscriptCount: Int {
        dualStreamService?.metricsSnapshot.system.nonEmptyTranscriptCount ?? 0
    }

    @MainActor
    var deepgramSystemLastError: String {
        dualStreamService?.metricsSnapshot.system.lastError ?? "none"
    }

    @MainActor
    var transcriptConflictMicSuppressedCount: Int {
        transcriptMerger?.conflictStatsSnapshot.micDuplicatesSuppressed ?? 0
    }

    @MainActor
    var transcriptConflictSystemSuppressedCount: Int {
        transcriptMerger?.conflictStatsSnapshot.systemDuplicatesSuppressed ?? 0
    }

    @MainActor
    var transcriptConflictRetroCorrectionCount: Int {
        transcriptMerger?.conflictStatsSnapshot.retroactiveCorrections ?? 0
    }

    @MainActor
    var transcriptConflictLastDecision: String {
        transcriptMerger?.conflictStatsSnapshot.lastDecision ?? "none"
    }
}
