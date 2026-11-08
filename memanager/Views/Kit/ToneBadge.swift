import SwiftUI

/// Small capsule chip carrying a semantic tone. Replaces the several badge
/// vocabularies that used to coexist (inline badges, tier badges, tab chips).
struct ToneBadge: View {
    enum Style {
        case tinted
        case outline
        case solid
    }

    let text: String
    var tone: OverlayTone = .neutral
    var systemImage: String? = nil
    var style: Style = .tinted
    var monospaced: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(OverlayType.symbol(9))
            }
            Text(text)
                .font(monospaced ? OverlayType.monoMicro : OverlayType.micro)
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(fill))
        .overlay(Capsule().stroke(stroke, lineWidth: 1))
        .fixedSize()
    }

    private var foreground: Color {
        switch style {
        case .tinted, .outline: return tone == .neutral ? OverlayPalette.textSecondary : tone.color
        case .solid: return tone == .neutral ? OverlayPalette.textPrimary : OverlayPalette.onAccent
        }
    }

    private var fill: Color {
        switch style {
        case .tinted: return tone.tint
        case .outline: return .clear
        case .solid: return tone == .neutral ? OverlayPalette.surfaceOverlay : tone.color.opacity(0.9)
        }
    }

    private var stroke: Color {
        switch style {
        case .tinted: return .clear
        case .outline: return tone.stroke
        case .solid: return .clear
        }
    }
}

/// Count pill used next to headers and list rows.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(OverlayType.monoMicro)
            .foregroundStyle(OverlayPalette.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(OverlayPalette.surfaceOverlay))
    }
}
