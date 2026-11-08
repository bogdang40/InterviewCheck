import Foundation

/// One of the four debrief sections with the tone its card carries.
struct DebriefSectionModel: Identifiable, Equatable {
    let id: String
    let title: String
    let tone: OverlayTone
    let lines: [String]
}

/// The four section read in under a minute after a session: what happened,
/// strong moments, missed opportunities, next focus.
enum DebriefSectionCatalog {
    static func sections(for debrief: SessionDebrief) -> [DebriefSectionModel] {
        [
            DebriefSectionModel(id: "what_happened", title: "What happened", tone: .info, lines: debrief.whatHappened),
            DebriefSectionModel(id: "strong_moments", title: "Strong moments", tone: .success, lines: debrief.strongMoments),
            DebriefSectionModel(id: "missed_opportunities", title: "Missed opportunities", tone: .warning, lines: debrief.missedOpportunities),
            DebriefSectionModel(id: "next_focus", title: "Next focus", tone: .neutral, lines: debrief.nextSessionFocus)
        ]
    }
}
