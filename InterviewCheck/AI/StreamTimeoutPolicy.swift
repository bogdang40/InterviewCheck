import Foundation

/// Staged timeout budgets for one streaming request, per session profile.
///
/// URLSession's request timeout resets whenever data arrives, so it cannot
/// distinguish "still thinking" from "connection silently died". These
/// budgets drive the StreamWatchdog, which raises typed timeout errors while
/// leaving genuinely active streams uncapped between chunks.
struct StreamTimeoutPolicy: Equatable {
    /// Allowance before the first stream line arrives.
    let firstByte: TimeInterval
    /// Allowance between lines once the stream is active.
    let interChunk: TimeInterval
    /// Total wall clock budget for the whole stream.
    let total: TimeInterval

    static func policy(for profile: AINetworkSession.SessionProfile) -> StreamTimeoutPolicy {
        switch profile {
        case .solve, .debrief:
            return StreamTimeoutPolicy(firstByte: 120, interChunk: 90, total: 30 * 60)
        case .quickAssist, .mlGuide:
            return StreamTimeoutPolicy(firstByte: 90, interChunk: 60, total: 15 * 60)
        }
    }
}
