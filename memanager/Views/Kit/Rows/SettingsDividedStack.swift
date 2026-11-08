import SwiftUI

/// Vertical stack that draws a hairline between each pair of children, so a
/// section can list rows without every row knowing whether it is last.
/// Conditional children that resolve to nothing produce no divider.
struct SettingsDividedStack<Content: View>: View {
    var inset: CGFloat = DesignTokens.Spacing.md
    @ViewBuilder let content: () -> Content

    var body: some View {
        _VariadicView.Tree(SettingsDividedStackRoot(inset: inset)) {
            content()
        }
    }
}

private struct SettingsDividedStackRoot: _VariadicView_UnaryViewRoot {
    let inset: CGFloat

    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let lastID = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != lastID {
                    Hairline()
                        .padding(.horizontal, inset)
                }
            }
        }
    }
}
