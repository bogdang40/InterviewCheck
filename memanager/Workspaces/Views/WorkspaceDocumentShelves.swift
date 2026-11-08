import Foundation

/// One shelf of the workspace folder with the files indexed on it.
struct WorkspaceDocumentShelf: Identifiable, Equatable {
    let category: WorkspaceDocumentCategory
    let documents: [WorkspaceDocument]

    var id: WorkspaceDocumentCategory { category }
}

/// Groups indexed files by shelf in the order the prompt reads them (job
/// description first, journal last), dropping the shelves that hold
/// nothing. One pass over the documents.
enum WorkspaceDocumentShelves {
    private static let orderedCategories = WorkspaceDocumentCategory.allCases
        .sorted { $0.contextPriority < $1.contextPriority }

    static func group(_ documents: [WorkspaceDocument]) -> [WorkspaceDocumentShelf] {
        let byCategory = Dictionary(grouping: documents, by: \.category)
        return orderedCategories.compactMap { category in
            guard let items = byCategory[category], !items.isEmpty else { return nil }
            return WorkspaceDocumentShelf(category: category, documents: items)
        }
    }
}
