import SwiftUI

/// Primary destinations stay labelled even in the narrow overlay.
struct CommandBar: View {
    let width: CGFloat
    let destination: OverlayDestination
    let onSelect: (OverlayDestination) -> Void
    var height: CGFloat = OverlayLayout.commandBarHeight
    var horizontalInset: CGFloat? = nil

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Color.clear.frame(width: 32)
                Text("Abley")
                    .font(.system(size: width < 560 ? 14 : 17, weight: .medium))
                    .foregroundStyle(OverlayPalette.textPrimary)
            }
            Spacer(minLength: 0)
            if width < 560 {
                Menu {
                    ForEach([OverlayDestination.live, .prepare, .review]) { item in
                        Button(item.title) { onSelect(item) }
                    }
                } label: {
                    Text(destination == .settings ? "Navigate" : destination.title)
                        .font(OverlayType.callout)
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Main destination")
            } else {
                HStack(spacing: 6) {
                    ForEach([OverlayDestination.live, .prepare, .review]) { item in
                        destinationButton(item)
                    }
                }
            }
            Spacer(minLength: 0)
            destinationButton(.settings)
        }
        .padding(.horizontal, horizontalInset ?? (width < 560 ? 16 : 24))
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation")
    }

    private func destinationButton(_ item: OverlayDestination) -> some View {
        Button { onSelect(item) } label: {
            HStack(spacing: 6) {
                if item == .settings { Image(systemName: "gearshape") }
                Text(item.title)
            }
            .font(.system(size: 13, weight: destination == item ? .medium : .regular))
            .foregroundStyle(OverlayPalette.textPrimary)
            .padding(.horizontal, item == .settings ? 10 : 18)
            .frame(height: 38)
            .background {
                if destination == item { PearlControlPlate() }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("destination.\(item.rawValue)")
        .accessibilityAddTraits(destination == item ? .isSelected : [])
    }
}
