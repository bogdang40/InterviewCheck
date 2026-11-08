import SwiftUI

/// The streaming caret: solid while chunks are arriving, blinking once the
/// stream pauses. TimelineView confines the 2 Hz invalidation to this one
/// glyph instead of the whole streaming body.
struct StreamingCursorView: View {
    /// Any value that changes when new text arrives (typically text length).
    let textRevision: Int
    let fontSize: CGFloat

    @State private var lastChangeAt = Date()

    /// Solid within the idle window so the caret reads as "writing",
    /// blinking only during genuine pauses.
    private let solidIdleWindow: TimeInterval = 0.2

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            Text("\u{258C}")
                .font(OverlayType.body(fontSize))
                .foregroundStyle(OverlayPalette.textPrimary.opacity(DesignTokens.Opacity.Text.cursor))
                .opacity(opacity(at: context.date))
        }
        .onAppear { lastChangeAt = Date() }
        .onChange(of: textRevision) { _, _ in lastChangeAt = Date() }
        .accessibilityHidden(true)
    }

    private func opacity(at date: Date) -> Double {
        if date.timeIntervalSince(lastChangeAt) <= solidIdleWindow {
            return 1
        }
        let halfSeconds = Int(date.timeIntervalSinceReferenceDate * 2)
        return halfSeconds.isMultiple(of: 2) ? 1 : 0
    }
}
