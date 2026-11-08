import SwiftUI

/// One entry in a `SegmentStrip`.
struct SegmentItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    var systemImage: String? = nil
    var shortcut: String? = nil
    var tone: OverlayTone? = nil
}

/// Horizontal segmented selector used for surfaces, stages, and modes. It
/// scrolls when the overlay is narrower than its labels and can collapse to
/// icons only.
struct SegmentStrip<ID: Hashable>: View {
    let items: [SegmentItem<ID>]
    @Binding var selection: ID
    var iconsOnly: Bool = false
    var showsShortcuts: Bool = false
    var expandsToFill: Bool = false
    var onSelect: ((ID) -> Void)? = nil

    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        Group {
            if expandsToFill { segments }
            else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) { segments }
                        .scrollBounceBehavior(.basedOnSize)
                        .task(id: ScrollTarget(selection: selection, width: viewportWidth)) {
                            // Measurement already follows layout. Reveal in this task
                            // turn instead of deferring past a possible view replacement.
                            guard viewportWidth > 0, !Task.isCancelled else { return }
                            proxy.scrollTo(selection, anchor: .center)
                        }
                        .background {
                            GeometryReader { viewport in
                                Color.clear
                                    .onChange(of: viewport.size.width, initial: true) { _, width in
                                        viewportWidth = width
                                    }
                            }
                        }
                }
            }
        }
    }

    private struct ScrollTarget: Equatable {
        let selection: ID
        let width: CGFloat
    }

    private var segments: some View {
        HStack(spacing: expandsToFill ? 12 : 2) {
            ForEach(items) { item in
                SegmentStripButton(
                    item: item,
                    isSelected: item.id == selection,
                    iconsOnly: iconsOnly,
                    showsShortcut: showsShortcuts,
                    expandsToFill: expandsToFill
                ) {
                    selection = item.id
                    onSelect?(item.id)
                }
                .id(item.id)
            }
        }
        .padding(2)
    }
}

struct SegmentStripButton<ID: Hashable>: View {
    let item: SegmentItem<ID>
    let isSelected: Bool
    let iconsOnly: Bool
    let showsShortcut: Bool
    var expandsToFill: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage = item.systemImage {
                    Image(systemName: systemImage)
                        .font(OverlayType.symbol(11))
                }
                if !iconsOnly {
                    Text(item.title)
                        .font(OverlayType.callout)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if showsShortcut, !iconsOnly, let shortcut = item.shortcut {
                    KeyCap(shortcut: shortcut)
                }
                if let tone = item.tone {
                    Circle()
                        .fill(tone.color)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(isSelected ? OverlayPalette.textPrimary : OverlayPalette.textSecondary)
            .padding(.horizontal, iconsOnly ? 8 : 10)
            .frame(minHeight: 32)
            .frame(maxWidth: expandsToFill ? .infinity : nil)
            .background {
                if isSelected { PearlControlPlate(radius: DesignTokens.Radius.sm) }
                else { shape.fill(fill) }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(DesignTokens.Motion.focus, value: isHovering)
    }

    private var fill: Color {
        if isSelected { return OverlayPalette.accentTint }
        if isHovering { return OverlayPalette.surfaceRaised }
        return .clear
    }

    private var helpText: String {
        if let shortcut = item.shortcut {
            return "\(item.title) (\(shortcut))"
        }
        return item.title
    }
}
