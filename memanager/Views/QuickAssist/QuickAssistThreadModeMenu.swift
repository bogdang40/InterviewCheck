import SwiftUI

/// The thread mode as one compact menu showing the selected mode, with a
/// caption when the router resolved a different mode for the last turn.
struct QuickAssistThreadModeMenu: View {
    let selectedMode: QuickAssistThreadMode
    let resolvedCaption: String?
    let showsCaption: Bool
    let isLoading: Bool
    let onSetMode: (QuickAssistThreadMode) -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Menu {
                ForEach(QuickAssistThreadMode.allCases, id: \.self) { mode in
                    Button {
                        onSetMode(mode)
                    } label: {
                        if mode == selectedMode {
                            Label(mode.displayName, systemImage: "checkmark")
                        } else {
                            Text(mode.displayName)
                        }
                    }
                }
            } label: {
                OverlayMenuLabel(
                    title: selectedMode.displayName,
                    systemImage: "slider.horizontal.3",
                    isActive: selectedMode != .auto
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isLoading)
            .help(helpText)
            .accessibilityLabel("Thread mode \(selectedMode.displayName)")

            if showsCaption, let resolvedCaption {
                Text(resolvedCaption)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let resolvedCaption {
                Circle()
                    .fill(OverlayTone.info.color)
                    .frame(width: 5, height: 5)
                    .help(resolvedCaption)
            }
        }
    }

    private var helpText: String {
        var text = "Thread mode (\(ShortcutCatalog.quickAssistCycleMode) cycles)"
        if let resolvedCaption {
            text += ", last turn \(resolvedCaption)"
        }
        return text
    }
}
