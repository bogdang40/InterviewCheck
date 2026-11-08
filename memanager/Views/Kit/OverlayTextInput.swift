import SwiftUI

/// Single line text input in the overlay's field chrome. The focus ring
/// follows the field so every form shares one look.
struct OverlayTextInput: View {
    let placeholder: String
    @Binding var text: String
    var font: Font = OverlayType.body

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .font(font)
            .foregroundStyle(OverlayPalette.textPrimary)
            .focused($isFocused)
            .overlayField(isFocused: isFocused)
    }
}
