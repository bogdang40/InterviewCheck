import SwiftUI

/// The services a design names, each as a raised card with its purpose,
/// responsibilities, and stack.
struct DesignComponentsBlock: View {
    let components: [ComponentBlock]
    let fontSize: CGFloat

    var body: some View {
        if !components.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                ForEach(components) { component in
                    DesignComponentCard(component: component, fontSize: fontSize)
                }
            }
        }
    }
}

struct DesignComponentCard: View {
    let component: ComponentBlock
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: component.icon)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.accent)
                Text(component.name)
                    .font(OverlayType.bodyStrong(fontSize))
                    .foregroundStyle(OverlayPalette.textPrimary)
                Spacer(minLength: 0)
            }

            DesignProseBlock(text: component.description, fontSize: fontSize - 1)

            DesignBulletList(items: component.responsibilities, fontSize: fontSize - 1)

            if !component.technologies.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                    FieldLabel(text: "Stack")
                    Text(component.technologies.joined(separator: ", "))
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlayCard(.raised, cornerRadius: DesignTokens.Radius.md, padding: DesignTokens.Spacing.md)
    }
}
