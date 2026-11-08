import SwiftUI

/// Large tinted button for the four review grades.
struct PracticeGradeButtonStyle: ButtonStyle {
    let tone: OverlayTone

    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(shape.fill(tone.tint.opacity(configuration.isPressed ? 1.8 : 1)))
            .overlay(shape.stroke(tone.stroke, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .animation(DesignTokens.Motion.focus, value: configuration.isPressed)
    }
}
