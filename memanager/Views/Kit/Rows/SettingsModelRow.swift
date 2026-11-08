import SwiftUI

/// A model picker: a menu of the curated identifiers plus a Custom entry
/// that reveals a text field for anything the menu does not list.
struct SettingsModelRow: View {
    let title: String
    var helper: String? = nil
    let curated: [String]
    @Binding var model: String
    var placeholder: String = "model identifier"

    @State private var isCustom = false
    @FocusState private var isFocused: Bool

    private var choice: ModelChoice {
        ModelChoiceResolver.choice(for: model, curated: curated)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: title, helper: helper) {
                OverlayMenuButton(title: isCustom ? ModelChoiceResolver.customTitle : ModelChoiceResolver.menuTitle(for: choice)) {
                    ForEach(curated, id: \.self) { candidate in
                        Button {
                            select(candidate)
                        } label: {
                            if !isCustom, candidate == choice.model {
                                Label(candidate, systemImage: "checkmark")
                            } else {
                                Text(candidate)
                            }
                        }
                    }
                    Divider()
                    Button {
                        select(nil)
                    } label: {
                        if isCustom {
                            Label(ModelChoiceResolver.customTitle, systemImage: "checkmark")
                        } else {
                            Text(ModelChoiceResolver.customTitle)
                        }
                    }
                }
            }
            if isCustom {
                TextField(placeholder, text: $model)
                    .font(OverlayType.mono)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .focused($isFocused)
                    .autocorrectionDisabled()
                    .overlayField(isFocused: isFocused)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.bottom, SettingsRowMetrics.verticalPadding)
            }
        }
        .onAppear { isCustom = choice.isCustom }
        .onChange(of: curated) { _, _ in isCustom = choice.isCustom }
    }

    private func select(_ candidate: String?) {
        model = ModelChoiceResolver.model(afterSelecting: candidate, current: model, curated: curated)
        withAnimation(DesignTokens.Motion.sectionExpand) {
            isCustom = candidate == nil
        }
        if candidate == nil { isFocused = true }
    }
}
