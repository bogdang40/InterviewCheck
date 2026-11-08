import SwiftUI

/// Plain streaming text: no markdown parsing while chunks arrive, so the
/// first token paints as soon as it lands.
struct StreamingTextView: View {
    let text: String
    let fontSize: CGFloat
    let scrollTarget: ScrollTarget?
    let autoScrollMode: StreamingAutoScrollMode
    let programmaticFollowPolicy: StreamingProgrammaticFollowPolicy

    init(
        text: String,
        fontSize: CGFloat = 14,
        scrollTarget: ScrollTarget? = nil,
        autoScrollMode: StreamingAutoScrollMode = .smart,
        programmaticFollowPolicy: StreamingProgrammaticFollowPolicy = .lockDuringProgrammaticScroll
    ) {
        self.text = text
        self.fontSize = fontSize
        self.scrollTarget = scrollTarget
        self.autoScrollMode = autoScrollMode
        self.programmaticFollowPolicy = programmaticFollowPolicy
    }

    var body: some View {
        StreamingTextContainer(
            text: text,
            scrollTarget: scrollTarget,
            autoScrollMode: autoScrollMode,
            programmaticFollowPolicy: programmaticFollowPolicy
        ) {
            Text(text)
                .font(OverlayType.body(fontSize))
                .foregroundStyle(OverlayPalette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Streaming text with the caret: solid while chunks arrive, blinking
/// once the stream pauses.
struct StreamingTextWithCursor: View {
    let text: String
    let fontSize: CGFloat
    let maxWidth: CGFloat?
    let scrollTarget: ScrollTarget?
    let autoScrollMode: StreamingAutoScrollMode
    let programmaticFollowPolicy: StreamingProgrammaticFollowPolicy

    init(
        text: String,
        fontSize: CGFloat = 14,
        maxWidth: CGFloat? = nil,
        scrollTarget: ScrollTarget? = nil,
        autoScrollMode: StreamingAutoScrollMode = .smart,
        programmaticFollowPolicy: StreamingProgrammaticFollowPolicy = .lockDuringProgrammaticScroll
    ) {
        self.text = text
        self.fontSize = fontSize
        self.maxWidth = maxWidth
        self.scrollTarget = scrollTarget
        self.autoScrollMode = autoScrollMode
        self.programmaticFollowPolicy = programmaticFollowPolicy
    }

    var body: some View {
        StreamingTextContainer(
            text: text,
            scrollTarget: scrollTarget,
            autoScrollMode: autoScrollMode,
            programmaticFollowPolicy: programmaticFollowPolicy
        ) {
            HStack(alignment: .bottom, spacing: 0) {
                Text(text)
                    .font(OverlayType.body(fontSize))
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(6)
                    .frame(maxWidth: maxWidth, alignment: .leading)
                StreamingCursorView(textRevision: text.count, fontSize: fontSize)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
