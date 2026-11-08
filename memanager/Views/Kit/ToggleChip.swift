import SwiftUI

/// A tone badge that behaves as a toggle. Active chips fill with a tone
/// tint, inactive chips stay a neutral outline, so the active set reads at
/// a glance. Used for session filters and timeline event types.
struct ToggleChip: View {
    let title: String
    let isActive: Bool
    var systemImage: String? = nil
    var activeTone: OverlayTone = .info
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ToneBadge(
                text: title,
                tone: isActive ? activeTone : .neutral,
                systemImage: systemImage,
                style: isActive ? .tinted : .outline
            )
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
