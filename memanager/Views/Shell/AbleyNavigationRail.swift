import SwiftUI

/// Destination navigation is independent from the current live task.
struct AbleyNavigationRail: View {
    let width: CGFloat
    let isCompact: Bool
    let destination: OverlayDestination
    let onSelect: (OverlayDestination) -> Void

    var body: some View {
        Group {
            if isCompact {
                CommandBar(width: width, destination: destination, onSelect: onSelect,
                           height: 44, horizontalInset: 12)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        // The welcome presentation owns the interactive mascot.
                        Color.clear.frame(width: 32, height: 32)
                        Text(AppBrand.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(OverlayPalette.textPrimary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 72)

                    ForEach([OverlayDestination.live, .prepare, .review]) { item in
                        destinationButton(item)
                    }
                    Spacer(minLength: 12)
                    Hairline().padding(.horizontal, 18)
                    destinationButton(.settings)
                        .padding(.bottom, 14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation")
    }

    private func destinationButton(_ item: OverlayDestination) -> some View {
        Button { onSelect(item) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol(for: item))
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 26)
                Text(item.title)
                    .font(.system(size: 14, weight: destination == item ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(destination == item ? OverlayPalette.accent : OverlayPalette.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background {
                if destination == item {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(OverlayPalette.accent.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(OverlayPalette.glassHighlight.opacity(0.16), lineWidth: 1))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityIdentifier("destination.\(item.rawValue)")
        .accessibilityAddTraits(destination == item ? .isSelected : [])
    }

    private func symbol(for destination: OverlayDestination) -> String {
        switch destination {
        case .live: return "waveform.path"
        case .prepare: return "briefcase"
        case .review: return "doc.text.magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}
