import SwiftUI

/// One choice offered by a `SettingsPickerRow`.
struct SettingsPickerOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

/// A labelled menu of choices. The current title is printed on the button
/// so the value can be read without opening the menu.
struct SettingsPickerRow<Value: Hashable>: View {
    let title: String
    var helper: String? = nil
    let options: [SettingsPickerOption<Value>]
    @Binding var selection: Value
    var isEnabled: Bool = true

    private var currentTitle: String {
        options.first(where: { $0.value == selection })?.title ?? "Choose"
    }

    var body: some View {
        SettingsRow(title: title, helper: helper) {
            OverlayMenuButton(title: currentTitle, isEnabled: isEnabled) {
                ForEach(options) { option in
                    Button {
                        selection = option.value
                    } label: {
                        if option.value == selection {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
        }
    }
}
