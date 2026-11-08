import Foundation

/// Keeps the selected workspace valid: what is selected wins while it
/// exists, then the active workspace, then the first in the sorted list.
enum WorkspaceSelectionResolver {
    static func resolve(current: UUID?, active: UUID?, sorted: [JobWorkspace]) -> UUID? {
        let ids = Set(sorted.map(\.id))
        if let current, ids.contains(current) { return current }
        if let active, ids.contains(active) { return active }
        return sorted.first?.id
    }
}
