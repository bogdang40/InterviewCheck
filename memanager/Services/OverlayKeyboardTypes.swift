import Foundation

enum OverlayFocusTarget: String, CaseIterable {
    case sectionTabs
    case quickAssistQuestion
    case quickAssistExtraContext
    case quickAssistRouteOverride
    case quickAssistRelatedMemory
    case quickAssistHistorySearch
    case quickAssistHistoryThreads
    case quickAssistThreadTools
    case liveResponseActions
    case transcriptView
    case diagnosticsActions

    var displayName: String {
        switch self {
        case .sectionTabs:
            return "Sections"
        case .quickAssistQuestion:
            return "Quick Assist Question"
        case .quickAssistExtraContext:
            return "Quick Assist Extra Context"
        case .quickAssistRouteOverride:
            return "Mode Selector"
        case .quickAssistRelatedMemory:
            return "Related Memory"
        case .quickAssistHistorySearch:
            return "History Search"
        case .quickAssistHistoryThreads:
            return "History Threads"
        case .quickAssistThreadTools:
            return "Thread Tools"
        case .liveResponseActions:
            return "Live Response Actions"
        case .transcriptView:
            return "Transcript"
        case .diagnosticsActions:
            return "Diagnostics"
        }
    }
}

struct OverlaySelectionState: Equatable {
    var relatedMemoryIndex: Int = 0
    var threadToolActionIndex: Int = 0
    var liveResponseActionIndex: Int = 0
    var diagnosticsActionIndex: Int = 0
    var routeOverrideIndex: Int = 0
}

enum OverlayCommand: Equatable {
    case nextFocus
    case previousFocus
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case activate
    case space
    case dismiss
    case deleteBackward
    case deleteSelection
    case insertText(String)
}

enum OverlayThreadToolAction: String, CaseIterable {
    case branch
    case timeline
    case compareExperiment
    case adoptWinner
    case clearExperiment

    var displayName: String {
        switch self {
        case .branch:
            return "Branch From Turn"
        case .timeline:
            return "Open Timeline"
        case .compareExperiment:
            return "Compare"
        case .adoptWinner:
            return "Adopt Winner"
        case .clearExperiment:
            return "Clear Experiment"
        }
    }
}

enum OverlayLiveResponseAction: String, CaseIterable {
    case cycle
    case pin
    case refine
    case dismiss

    var displayName: String {
        switch self {
        case .cycle:
            return "Cycle"
        case .pin:
            return "Pin"
        case .refine:
            return "Refine"
        case .dismiss:
            return "Dismiss"
        }
    }
}

enum OverlayDiagnosticsAction: String, CaseIterable {
    case retrySystemStream
    case refreshPermissions
    case close

    var displayName: String {
        switch self {
        case .retrySystemStream:
            return "Retry System Stream"
        case .refreshPermissions:
            return "Refresh Permissions"
        case .close:
            return "Close Diagnostics"
        }
    }
}

