import SwiftUI

/// Icon toggle for the project tool loop. The menu carries the switch and
/// explains why tools are unavailable when the active Mode has no folder,
/// the bound root drifted, or the provider does not support the loop.
struct QuickAssistToolsMenu: View {
    @Binding var isOn: Bool
    let availability: QuickAssistToolAvailability
    let runningToolCount: Int

    private var isEffectivelyOn: Bool {
        isOn && availability.isAvailable
    }

    var body: some View {
        Menu {
            Toggle("Force tools on the next turn", isOn: $isOn)
                .disabled(!availability.isAvailable)
            if runningToolCount > 0 {
                Text(runningToolCount == 1 ? "1 tool running" : "\(runningToolCount) tools running")
            }
            Divider()
            Text(availability.helpText)
        } label: {
            OverlayIconMenuLabel(
                systemImage: isEffectivelyOn ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver",
                isActive: isEffectivelyOn,
                isDimmed: !availability.isAvailable
            )
            .overlay(alignment: .topTrailing) {
                if runningToolCount > 0 {
                    Circle()
                        .fill(OverlayTone.info.color)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helpText)
        .accessibilityLabel(availability.isAvailable ? (isOn ? "Tools on" : "Tools off") : availability.disabledLabel)
    }

    private var helpText: String {
        guard availability.isAvailable else { return availability.helpText }
        return isOn
            ? "Tools are forced on the next turn. \(availability.helpText)"
            : "Tools are off for the next turn. \(availability.helpText)"
    }
}
