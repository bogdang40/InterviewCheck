import SwiftUI

/// The single place a section id becomes a color. Sections take the stable
/// speaker palette by blueprint position, so a section keeps one hue across
/// the section list, the overview, and the script.
enum DesignSectionToneResolver {
    /// Index into `OverlayPalette.speaker(_:)` for a section id. Unknown ids
    /// fall back to the first slot so a stray section never breaks a view.
    static func speakerIndex(for sectionID: String) -> Int {
        DesignSectionCatalog.section(id: sectionID)?.blueprintIndex ?? 0
    }

    static func color(for sectionID: String) -> Color {
        OverlayPalette.speaker(speakerIndex(for: sectionID))
    }
}
