import SwiftUI

/// Sort order as a compact menu and the session filters as toggle chips,
/// on one scrolling row so the list column keeps its width.
struct SessionFilterBar: View {
    @Binding var resolver: SessionListResolver

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                sortMenu
                Hairline(axis: .vertical)
                    .frame(height: 14)
                    .padding(.horizontal, DesignTokens.Spacing.xxs)
                ForEach(SessionFilter.allCases) { filter in
                    ToggleChip(
                        title: filter.chipTitle,
                        isActive: resolver.filters.contains(filter),
                        systemImage: filter.systemImage
                    ) {
                        resolver.toggle(filter)
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var sortMenu: some View {
        OverlayMenuButton(title: resolver.sortOrder.rawValue, systemImage: "arrow.up.arrow.down") {
            ForEach(SessionSortOrder.allCases) { order in
                Button {
                    resolver.sortOrder = order
                } label: {
                    if order == resolver.sortOrder {
                        Label(order.rawValue, systemImage: "checkmark")
                    } else {
                        Text(order.rawValue)
                    }
                }
            }
        }
    }
}

private extension SessionFilter {
    var chipTitle: String {
        switch self {
        case .hasDebrief: return "Debrief"
        case .hasCoachFindings: return "Coach"
        case .highActivity: return "Active"
        }
    }

    var systemImage: String {
        switch self {
        case .hasDebrief: return "doc.text"
        case .hasCoachFindings: return "figure.wave"
        case .highActivity: return "bolt"
        }
    }
}
