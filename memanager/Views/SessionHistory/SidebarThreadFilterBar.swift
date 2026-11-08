import SwiftUI

/// Filter chips for the thread list. "All" clears the set; each other chip
/// toggles a filter and lights up while active.
struct SidebarThreadFilterBar: View {
    @Binding var activeFilters: Set<SidebarThreadFilter>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                chip("All", isActive: activeFilters.isEmpty) {
                    activeFilters.removeAll()
                }
                ForEach(SidebarThreadFilter.allCases) { filter in
                    chip(filter.rawValue, isActive: activeFilters.contains(filter)) {
                        toggle(filter)
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func chip(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ToneBadge(text: title, tone: isActive ? .info : .neutral, style: isActive ? .tinted : .outline)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func toggle(_ filter: SidebarThreadFilter) {
        if activeFilters.contains(filter) {
            activeFilters.remove(filter)
        } else {
            activeFilters.insert(filter)
        }
    }
}
