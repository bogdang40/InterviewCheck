import SwiftUI

/// Turns a shortcut description such as "Cmd+Shift+S" into the glyph
/// string macOS users expect ("⌘⇧S"). Pure, so it can be unit tested.
enum KeyCapFormatter {
    private static let glyphs: [String: String] = [
        "cmd": "⌘", "command": "⌘",
        "shift": "⇧",
        "option": "⌥", "opt": "⌥", "alt": "⌥",
        "ctrl": "⌃", "control": "⌃",
        "return": "↩", "enter": "↩",
        "escape": "⎋", "esc": "⎋",
        "delete": "⌫", "backspace": "⌫",
        "tab": "⇥",
        "space": "␣",
        "left": "←", "right": "→", "up": "↑", "down": "↓"
    ]

    static func glyphs(for shortcut: String) -> String {
        shortcut
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { token -> String in
                let trimmed = token.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return "+" }
                return glyph(for: trimmed)
            }
            .joined()
    }

    private static func glyph(for token: String) -> String {
        if token.count > 1, token.contains("/") {
            return token.split(separator: "/").map { glyph(for: String($0)) }.joined(separator: "/")
        }
        if let mapped = glyphs[token.lowercased()] { return mapped }
        if let range = numericRange(token) { return "\(range.lowerBound)…\(range.upperBound)" }
        if token.lowercased() == "arrow keys" || token.lowercased() == "arrows" { return "↑↓←→" }
        return token.count == 1 ? token.uppercased() : token
    }

    /// Registry entries describe grouped chords as "1-6"; the caps show
    /// the range with an ellipsis instead of a dash.
    private static func numericRange(_ token: String) -> ClosedRange<Int>? {
        let parts = token.split(separator: "-")
        guard parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]), low < high else { return nil }
        return low...high
    }
}

/// A single key cap chip showing the glyphs for a shortcut.
struct KeyCap: View {
    let shortcut: String
    var emphasized: Bool = false

    var body: some View {
        Text(KeyCapFormatter.glyphs(for: shortcut))
            .font(OverlayType.monoMicro)
            .foregroundStyle(emphasized ? OverlayPalette.textPrimary : OverlayPalette.textTertiary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
                    .fill(OverlayPalette.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xs, style: .continuous)
                    .stroke(OverlayPalette.hairline, lineWidth: 1)
            )
            .accessibilityLabel(shortcut)
    }
}

/// A label followed by its key cap, for hint rows and status bars.
struct KeyHint: View {
    let label: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textTertiary)
                .lineLimit(1)
            KeyCap(shortcut: shortcut)
        }
        .fixedSize()
    }
}
