import Foundation

/// Everything the verification strip prints, derived once from the record.
struct QuickAssistVerificationStripModel: Equatable {
    let status: QuickAssistVerificationStatus
    let isStreaming: Bool
    let confidenceLabel: String?
    let unsupportedLabel: String?

    init(record: QuickAssistVerificationRecord?, isStreaming: Bool) {
        self.status = record?.status ?? .pending
        self.isStreaming = isStreaming
        self.confidenceLabel = Self.confidenceLabel(record?.confidence)
        self.unsupportedLabel = Self.unsupportedLabel(record?.unsupportedClaimCount ?? 0)
    }

    var statusLabel: String {
        isStreaming ? "Streaming" : status.displayLabel
    }

    var tone: OverlayTone {
        isStreaming ? .info : status.tone
    }

    var systemImage: String {
        isStreaming ? "dot.radiowaves.left.and.right" : status.systemImage
    }

    var dotState: StatusDotState {
        if isStreaming { return .streaming }
        switch status {
        case .pending: return .idle
        case .verified: return .ready
        case .needsReview, .failed: return .error
        }
    }

    static func confidenceLabel(_ confidence: Double?) -> String? {
        guard let confidence else { return nil }
        return "\(Int((confidence * 100).rounded()))%"
    }

    static func unsupportedLabel(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 unsupported claim" : "\(count) unsupported claims"
    }
}
