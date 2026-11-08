import Foundation

// MARK: - Skill Snapshot

/// Per-session performance metrics captured at debrief time.
struct SkillSnapshot {
    let sessionId: String
    let sessionDate: Date
    let verificationRate: Double
    let unsupportedClaimDensity: Double
    let coachFindingFrequency: Double
    let averageLatencyMs: Double
    let drillKinds: [SessionDrillKind]
}

// MARK: - Skill Trend

enum SkillTrendDirection: String {
    case improving
    case regressing
    case stable
}

/// Directional trend for a single metric across multiple sessions.
struct SkillTrend {
    let metric: String
    let direction: SkillTrendDirection
    let magnitude: Double
    let snapshotCount: Int
}

// MARK: - Skill Progression Report

/// Aggregated cross-session skill analysis.
struct SkillProgressionReport {
    let snapshots: [SkillSnapshot]
    let trends: [SkillTrend]
    let recurringWeakSpots: [SessionDrillKind]
    let promptBlock: String

    static let empty = SkillProgressionReport(
        snapshots: [],
        trends: [],
        recurringWeakSpots: [],
        promptBlock: ""
    )

    var isEmpty: Bool { snapshots.isEmpty }
}

// MARK: - Session Focus Context

/// Prior session focus items injected at the start of a new session.
struct SessionFocusContext {
    let focusItems: [String]
    let promptBlock: String

    static let empty = SessionFocusContext(focusItems: [], promptBlock: "")

    var isEmpty: Bool { focusItems.isEmpty }
}
