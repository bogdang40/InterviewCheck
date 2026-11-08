import SwiftUI

/// Follow incoming speech only while attached to the live end. Inspecting
/// an earlier line never gets interrupted by the next transcription chunk.
struct TranscriptList: View {
    let rows: [TranscriptRowModel]
    let density: TranscriptDensity
    let fontSize: CGFloat
    let scrollTarget: ScrollTarget?
    var useSourceBasedIdentification: Bool = false
    var onSpeakerTapped: ((Int) -> Void)? = nil

    var body: some View {
        StreamingTextContainer(
            text: rows.map { "\($0.id):\($0.text)" }.joined(separator: "\n"),
            scrollTarget: scrollTarget,
            autoScrollMode: .smart,
            programmaticFollowPolicy: .allowUserDetachment
        ) {
            LazyVStack(alignment: .leading, spacing: density.rowSpacing) {
                ForEach(rows) { row in
                    TranscriptRow(
                        row: row, density: density, fontSize: fontSize,
                        useSourceBasedIdentification: useSourceBasedIdentification,
                        onSpeakerTapped: onSpeakerTapped
                    )
                    .id(row.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
