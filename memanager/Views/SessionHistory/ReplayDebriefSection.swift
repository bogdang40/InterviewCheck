import SwiftUI

/// The next focus lines and the drills from the session's debrief.
struct ReplayDebriefSection: View {
    let debrief: SessionDebrief?

    @State private var isExpanded = true

    var body: some View {
        if let debrief {
            DisclosureCard("Debrief and drills", systemImage: "doc.text.magnifyingglass", count: debrief.drills.count, isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    if !debrief.nextSessionFocus.isEmpty {
                        FieldLabel(text: "Next focus")
                        ForEach(debrief.nextSessionFocus.prefix(3), id: \.self) { focus in
                            Text(focus)
                                .font(OverlayType.body)
                                .foregroundStyle(OverlayPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !debrief.drills.isEmpty {
                        FieldLabel(text: "Drills")
                        ForEach(debrief.drills.prefix(5)) { drill in
                            HStack(spacing: DesignTokens.Spacing.sm) {
                                ToneBadge(text: drill.kind.displayLabel, tone: .neutral, style: .outline)
                                Text(drill.title)
                                    .font(OverlayType.caption)
                                    .foregroundStyle(OverlayPalette.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }
}
