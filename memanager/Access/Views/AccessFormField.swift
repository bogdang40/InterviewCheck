import AppKit
import SwiftUI

/// One labelled input in the sign in form: a field label, the overlay's
/// input chrome, and an optional helper line beneath.
struct AccessFormField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var contentType: NSTextContentType? = nil
    var helper: String? = nil

    @FocusState private var isFocused: Bool
    @State private var revealsValue = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            FieldLabel(text: label)
            HStack {
                field
                    .textFieldStyle(.plain)
                if isSecure {
                    Button { revealsValue.toggle() } label: {
                        Image(systemName: revealsValue ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.overlayIcon(size: 24))
                    .accessibilityLabel(revealsValue ? "Hide \(label.lowercased())" : "Show \(label.lowercased())")
                }
            }
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textPrimary)
                .focused($isFocused)
                .autocorrectionDisabled()
                .overlayField(isFocused: isFocused)
            if let helper {
                Text(helper)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        if isSecure && !revealsValue {
            SecureField(placeholder, text: $text)
                .textContentType(contentType)
        } else {
            TextField(placeholder, text: $text)
                .textContentType(contentType)
        }
    }
}
