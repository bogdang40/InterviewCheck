import SwiftUI

/// One row of a `KeyValueGrid`.
struct KeyValuePair: Identifiable, Equatable {
    let key: String
    let value: String

    var id: String { key }

    /// Sorted rows from a dictionary, so the grid reads the same every time.
    static func sorted(_ dictionary: [String: String]) -> [KeyValuePair] {
        dictionary
            .sorted { $0.key < $1.key }
            .map { KeyValuePair(key: $0.key, value: $0.value) }
    }
}

/// Two column key value grid: keys in caption, values in mono, so
/// properties can be scanned like a table.
struct KeyValueGrid: View {
    let pairs: [KeyValuePair]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: DesignTokens.Spacing.md, verticalSpacing: DesignTokens.Spacing.xs) {
            ForEach(pairs) { pair in
                GridRow {
                    Text(pair.key)
                        .font(OverlayType.captionStrong)
                        .foregroundStyle(OverlayPalette.textTertiary)
                        .lineLimit(1)
                    Text(pair.value)
                        .font(OverlayType.mono)
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
