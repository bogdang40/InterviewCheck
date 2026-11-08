import Foundation

/// A chip in the composer telling the user what rides along with the
/// next question.
struct QuickAssistComposerContextHint: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case transcript
        case screenshot
        case pinnedMemory
        case previousTurn
        case fresh
    }

    let kind: Kind
    let label: String
    let iconName: String

    var id: String { kind.rawValue }
}

/// Builds the context chips from plain counts so the labels read as facts
/// ("3 screenshots", "2 pinned") instead of a name followed by a number.
enum QuickAssistContextHintBuilder {
    static func hints(
        hasTranscript: Bool,
        screenshotCount: Int,
        pinnedMemoryCount: Int,
        hasPriorTurn: Bool
    ) -> [QuickAssistComposerContextHint] {
        var hints: [QuickAssistComposerContextHint] = []
        if hasTranscript {
            hints.append(QuickAssistComposerContextHint(kind: .transcript, label: "Transcript", iconName: "waveform"))
        }
        if screenshotCount > 0 {
            hints.append(
                QuickAssistComposerContextHint(
                    kind: .screenshot,
                    label: screenshotCount == 1 ? "1 screenshot" : "\(screenshotCount) screenshots",
                    iconName: "photo.on.rectangle"
                )
            )
        }
        if pinnedMemoryCount > 0 {
            hints.append(
                QuickAssistComposerContextHint(kind: .pinnedMemory, label: "\(pinnedMemoryCount) pinned", iconName: "pin")
            )
        }
        if hasPriorTurn {
            hints.append(QuickAssistComposerContextHint(kind: .previousTurn, label: "Prior turn", iconName: "clock.arrow.circlepath"))
        }
        if hints.isEmpty {
            hints.append(QuickAssistComposerContextHint(kind: .fresh, label: "Fresh prompt", iconName: "sparkles"))
        }
        return hints
    }
}
