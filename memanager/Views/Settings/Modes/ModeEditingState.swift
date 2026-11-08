import Combine
import Foundation

struct ModeEditorDraft: Equatable {
    var title: String
    var prompt: String
    let originalTitle: String
    let originalPrompt: String

    init(mode: Mode) {
        title = mode.title
        prompt = mode.prompt
        originalTitle = mode.title
        originalPrompt = mode.prompt
    }

    var isDirty: Bool { title != originalTitle || prompt != originalPrompt }
}

/// Session drafts survive settings and destination changes. Saving merges text
/// into the current mode so a concurrent attachment change is never overwritten.
@MainActor
final class ModeEditingState: ObservableObject {
    static let shared = ModeEditingState()
    @Published var selectedModeID: UUID?
    @Published private(set) var drafts: [UUID: ModeEditorDraft] = [:]

    func draft(for mode: Mode) -> ModeEditorDraft {
        guard let draft = drafts[mode.id], draft.isDirty else { return ModeEditorDraft(mode: mode) }
        return draft
    }

    func update(_ mode: Mode, _ change: (inout ModeEditorDraft) -> Void) {
        var draft = draft(for: mode)
        change(&draft)
        drafts[mode.id] = draft
    }

    func save(modeID: UUID, store: ModeStore) {
        guard var current = store.mode(with: modeID), let draft = drafts[modeID] else { return }
        current.title = draft.title
        current.prompt = draft.prompt
        store.updateMode(current)
        drafts.removeValue(forKey: modeID)
    }

    func discard(modeID: UUID) { drafts.removeValue(forKey: modeID) }

    func retain(_ modes: [Mode]) {
        let ids = Set(modes.map(\.id))
        drafts = drafts.filter { ids.contains($0.key) }
        if selectedModeID.map({ !ids.contains($0) }) ?? true { selectedModeID = modes.first?.id }
    }
}
