import Foundation

/// A tracked skill metric and how it is read out of a snapshot.
struct SkillMetricDescriptor: Identifiable, Equatable {
    let key: String
    let label: String
    var id: String { key }
}

/// The four metrics the skill progression sparklines follow across sessions.
enum SkillMetricCatalog {
    static let tracked: [SkillMetricDescriptor] = [
        SkillMetricDescriptor(key: "verification_rate", label: "Verification"),
        SkillMetricDescriptor(key: "unsupported_claim_density", label: "Claim density"),
        SkillMetricDescriptor(key: "coach_finding_frequency", label: "Coach findings"),
        SkillMetricDescriptor(key: "average_latency", label: "Latency")
    ]

    static func values(for key: String, in report: SkillProgressionReport) -> [Double] {
        report.snapshots.map { snapshot in
            switch key {
            case "verification_rate": return snapshot.verificationRate
            case "unsupported_claim_density": return snapshot.unsupportedClaimDensity
            case "coach_finding_frequency": return snapshot.coachFindingFrequency
            case "average_latency": return snapshot.averageLatencyMs
            default: return 0
            }
        }
    }

    static func trend(for key: String, in report: SkillProgressionReport) -> SkillTrendDirection {
        report.trends.first { $0.metric == key }?.direction ?? .stable
    }
}

extension SkillTrendDirection {
    var tone: OverlayTone {
        switch self {
        case .improving: return .success
        case .regressing: return .critical
        case .stable: return .neutral
        }
    }

    var systemImage: String {
        switch self {
        case .improving: return "arrow.up.right"
        case .regressing: return "arrow.down.right"
        case .stable: return "arrow.right"
        }
    }
}
