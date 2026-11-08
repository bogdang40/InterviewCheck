import SwiftUI

/// Preserve each column's type, key role and description alongside the
/// access-pattern narrative and indexes.
struct DesignDatabaseBlock: View {
    let database: DatabaseBlock
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            DesignProseBlock(text: database.description, fontSize: fontSize)
            ForEach(database.tables) { table in
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text(table.name).font(OverlayType.heading).foregroundStyle(OverlayPalette.textPrimary)
                    ForEach(table.columns) { column in
                        Hairline()
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(column.name).font(OverlayType.mono)
                                Text(column.type).font(OverlayType.mono).foregroundStyle(OverlayPalette.textSecondary)
                                if column.isPrimaryKey { Text("Primary key").font(OverlayType.caption) }
                                if column.isForeignKey { Text("Foreign key").font(OverlayType.caption) }
                            }
                            .foregroundStyle(OverlayPalette.textPrimary).textSelection(.enabled)
                            if let description = column.description, !description.isEmpty {
                                Text(description).font(OverlayType.body(fontSize))
                                    .foregroundStyle(OverlayPalette.textSecondary).textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, DesignTokens.Spacing.xs)
                    }
                    if !table.indexes.isEmpty {
                        Text("Indexes: \(table.indexes.joined(separator: ", "))")
                            .font(OverlayType.caption).foregroundStyle(OverlayPalette.textSecondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
