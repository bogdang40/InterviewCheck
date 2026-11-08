import SwiftUI

/// Input well chrome shared by every text field and editor in the overlay:
/// a recessed fill, a hairline, and an accent ring while focused.
struct OverlayFieldModifier: ViewModifier {
    let isFocused: Bool
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(shape.fill(OverlayPalette.well))
            .overlay(
                shape.stroke(
                    isFocused ? OverlayPalette.accentStroke : OverlayPalette.hairline,
                    lineWidth: isFocused ? 1.5 : 1
                )
            )
            .animation(DesignTokens.Motion.focus, value: isFocused)
    }
}

extension View {
    func overlayField(
        isFocused: Bool = false,
        cornerRadius: CGFloat = DesignTokens.Radius.md,
        horizontalPadding: CGFloat = 10,
        verticalPadding: CGFloat = 7
    ) -> some View {
        modifier(
            OverlayFieldModifier(
                isFocused: isFocused,
                cornerRadius: cornerRadius,
                horizontalPadding: horizontalPadding,
                verticalPadding: verticalPadding
            )
        )
    }
}

/// Caption above a field or a group of controls.
struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(OverlayType.captionStrong)
            .foregroundStyle(OverlayPalette.textTertiary)
            .textCase(.uppercase)
            .kerning(0.4)
    }
}

/// Search field with a magnifier and a clear button.
struct OverlaySearchField: View {
    let placeholder: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding? = nil

    @FocusState private var localFocus: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(OverlayType.symbol(11))
                .foregroundStyle(OverlayPalette.textTertiary)
            field
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textPrimary)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(OverlayType.symbol(11, weight: .regular))
                        .foregroundStyle(OverlayPalette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .overlayField(isFocused: isFocused, cornerRadius: DesignTokens.Radius.md, verticalPadding: 6)
    }

    @ViewBuilder
    private var field: some View {
        if let focus {
            TextField(placeholder, text: $text)
                .focused(focus)
        } else {
            TextField(placeholder, text: $text)
                .focused($localFocus)
        }
    }

    private var isFocused: Bool {
        focus?.wrappedValue ?? localFocus
    }
}
