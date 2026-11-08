import SwiftUI

/// Toggle chips for the event types shown on the timeline lane, with an
/// All chip that restores every type.
struct TimelineFilterChipBar: View {
    @Binding var enabledTypes: Set<WorkstreamEventType>

    private var allEnabled: Bool {
        enabledTypes.count == WorkstreamEventType.allCases.count
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ToggleChip(title: "All", isActive: allEnabled) {
                    enabledTypes = Set(WorkstreamEventType.allCases)
                }
                ForEach(WorkstreamEventType.allCases, id: \.rawValue) { type in
                    ToggleChip(title: type.shortTitle, isActive: enabledTypes.contains(type)) {
                        toggle(type)
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func toggle(_ type: WorkstreamEventType) {
        if enabledTypes.contains(type) {
            enabledTypes.remove(type)
        } else {
            enabledTypes.insert(type)
        }
    }
}
