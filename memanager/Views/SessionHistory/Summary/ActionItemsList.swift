import SwiftUI

/// Action items pulled from the session, each with its owner and due date.
struct ActionItemsList: View {
    let items: [SessionSummary.ActionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                FieldLabel(text: "Action items")
                CountBadge(count: items.count)
            }
            if items.isEmpty {
                Text("None recorded.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
            } else {
                ForEach(items) { item in
                    row(for: item)
                }
            }
        }
    }

    private func row(for item: SessionSummary.ActionItem) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "arrow.turn.down.right")
                .font(OverlayType.micro)
                .foregroundStyle(OverlayPalette.textTertiary)
                .padding(.top, DesignTokens.Spacing.xs)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(item.title)
                    .font(OverlayType.body)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                metadataLine(for: item)
                if let notes = item.notes, !notes.isEmpty {
                    Text(notes)
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func metadataLine(for item: SessionSummary.ActionItem) -> some View {
        let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let dueDate = item.dueDate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        WrappingFlowLayout(spacing: DesignTokens.Spacing.sm) {
            Label(owner.isEmpty ? "Owner not specified" : owner, systemImage: "person")
            Label(dueDate.isEmpty ? "Date not specified" : dueDate, systemImage: "calendar")
        }
        .font(OverlayType.caption)
        .foregroundStyle(OverlayPalette.textSecondary)
    }
}
