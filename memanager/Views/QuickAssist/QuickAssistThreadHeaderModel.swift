import Foundation

/// What the thread header shows, lifted out of the studio state so the row
/// can be reasoned about without bindings.
struct QuickAssistThreadHeaderModel: Equatable {
    let selectedTurnProvider: AIProviderType?
    let selectedResponseSourceLabel: String?
    let selectedOpenAIRawGuardedIdentical: Bool
    let responseCount: Int
    let selectedIndex: Int?
    let turnSummaries: [QuickAssistTurnSummary]
    let activeTier: QuickAssistModelTier
    let selectedMode: QuickAssistThreadMode
    let resolvedMode: QuickAssistThreadMode?
    let modeDiverges: Bool
    let isLoading: Bool
    let answerFamilyBadge: QuickAssistAnswerFamilyBadge?

    init(state: QuickAssistStudioState) {
        selectedTurnProvider = state.selectedTurnProvider
        selectedResponseSourceLabel = state.selectedResponseSourceLabel
        selectedOpenAIRawGuardedIdentical = state.selectedOpenAIRawGuardedIdentical
        responseCount = state.responseCount
        selectedIndex = state.selectedIndex
        turnSummaries = state.turnSummaries
        activeTier = state.activeTier
        selectedMode = state.selectedMode.wrappedValue
        resolvedMode = state.resolvedMode
        modeDiverges = state.modeDiverges
        isLoading = state.isLoading
        answerFamilyBadge = state.answerFamilyBadge
    }

    var modeItems: [QuickAssistThreadMode] {
        QuickAssistThreadMode.allCases
    }

    var shouldShowTurnNavigator: Bool {
        responseCount > 0
    }

    var providerDisplayName: String? {
        selectedTurnProvider?.displayName
    }

    var shouldShowOpenAISourceMenu: Bool {
        selectedTurnProvider == .openai
    }

    /// "Conflict · STAR" in one chip: the family the router picked and the
    /// framework the beats follow.
    var familyBadgeText: String? {
        guard let badge = answerFamilyBadge else { return nil }
        let framework = badge.frameworkName.trimmingCharacters(in: .whitespaces)
        return framework.isEmpty ? badge.familyName : "\(badge.familyName) · \(framework)"
    }

    var familyTone: OverlayTone {
        answerFamilyBadge?.isProbe == true ? .info : .success
    }

    var resolvedModeCaption: String? {
        guard modeDiverges, let resolvedMode else { return nil }
        return "resolved as \(resolvedMode.displayName)"
    }

    var navigator: QuickAssistTurnNavigatorModel {
        QuickAssistTurnNavigatorModel(turnSummaries: turnSummaries, selectedIndex: selectedIndex, isLoading: isLoading)
    }
}
