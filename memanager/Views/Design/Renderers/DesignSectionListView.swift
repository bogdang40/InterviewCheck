import SwiftUI

/// Local tabs select one section inside the current phase. Overview keeps
/// every available section reachable without an accordion of ten cards.
struct DesignSectionListView: View {
    let content: SystemDesignContent
    let sections: [DesignSection]
    @ObservedObject private var controller = SessionController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            DesignSectionNavigation(sections: sections)
            if sections.indices.contains(controller.systemDesignSectionIndex) {
                let index = controller.systemDesignSectionIndex
                DesignSectionCard(
                    section: sections[index], number: index + 1, total: sections.count,
                    content: content, isExpanded: true, onSelect: {}
                )
                .id(sections[index].id)
            }
        }
        .onAppear { controller.setSystemDesignSectionCount(sections.count) }
        .onChange(of: sections.count) { _, count in controller.setSystemDesignSectionCount(count) }
    }
}

struct DesignSectionNavigation: View {
    let sections: [DesignSection]
    @ObservedObject private var controller = SessionController.shared

    private var localItems: [SegmentItem<Int>] {
        let currentID = sections.indices.contains(controller.systemDesignSectionIndex)
            ? sections[controller.systemDesignSectionIndex].id : sections.first?.id
        let phase = currentID.flatMap(DesignPhaseCatalog.phaseIndex(forSectionID:))
        return sections.enumerated().compactMap { index, section in
            guard DesignPhaseCatalog.phaseIndex(forSectionID: section.id) == phase else { return nil }
            return SegmentItem(id: index, title: section.title)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if localItems.count > 1 { SegmentStrip(items: localItems, selection: $controller.systemDesignSectionIndex) }
            if !sections.isEmpty {
                Menu {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        Button(section.title) { controller.systemDesignSectionIndex = index }
                    }
                } label: {
                    Label("Section \(min(controller.systemDesignSectionIndex + 1, sections.count)) of \(sections.count)", systemImage: "list.bullet")
                        .font(OverlayType.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose any available section")
            }
        }
    }
}
