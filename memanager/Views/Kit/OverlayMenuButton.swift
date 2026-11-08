import SwiftUI

/// A menu drawn as one of the overlay's buttons, so popup choices sit in
/// rows without the stock popup chrome. Pass a title for a picker or only
/// a symbol for an actions menu. The button menu style hands the label to
/// the environment's button style, which keeps the chevron in place.
struct OverlayMenuButton<Items: View>: View {
    var title: String? = nil
    var systemImage: String? = nil
    var isEnabled: Bool = true
    @ViewBuilder var items: () -> Items

    var body: some View {
        Group {
            if let title {
                Menu {
                    items()
                } label: {
                    HStack(spacing: 6) {
                        Text(title)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(OverlayType.micro)
                            .foregroundStyle(OverlayPalette.textTertiary)
                    }
                }
                .buttonStyle(.overlay(.secondary, size: .small))
            } else {
                Menu {
                    items()
                } label: {
                    Image(systemName: systemImage ?? "ellipsis")
                }
                .buttonStyle(.overlayIcon(size: 24))
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isEnabled)
    }
}
