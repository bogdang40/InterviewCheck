import SwiftUI

/// Reasoning effort for one OpenAI path. Offers only the efforts the model
/// supports and prints the supported list with the default beneath, or says
/// the model does not use reasoning effort at all.
struct OpenAIReasoningEffortPickerRow: View {
    let title: String
    let model: String
    @Binding var selection: OpenAIReasoningEffort
    let onSelectionChange: (OpenAIReasoningEffort) -> Void

    private var supportedEfforts: [OpenAIReasoningEffort] {
        OpenAIReasoningEffortResolver.supportedEfforts(for: model)
    }

    private var helper: String {
        guard !supportedEfforts.isEmpty else { return "Not used for this model." }
        let supported = supportedEfforts.map(\.displayName).joined(separator: ", ")
        if let defaultEffort = OpenAIReasoningEffortResolver.defaultEffort(for: model) {
            return "Supported: \(supported). Default: \(defaultEffort.displayName)."
        }
        return "Supported: \(supported)."
    }

    var body: some View {
        Group {
            if supportedEfforts.isEmpty {
                SettingsRow(title: title, helper: helper) {
                    ToneBadge(text: "Not applicable", tone: .neutral)
                }
            } else {
                SettingsPickerRow(
                    title: title,
                    helper: helper,
                    options: supportedEfforts.map { SettingsPickerOption(value: $0, title: $0.displayName) },
                    selection: $selection
                )
            }
        }
        .onChange(of: selection) { _, newValue in
            onSelectionChange(newValue)
        }
    }
}
