import Foundation

/// Pure rules behind the metadata form's resync with the store.
extension WorkspaceMetadataForm {
    /// Equality over the fields this form edits, ignoring what the store
    /// stamps on every write.
    static func sameEditableContent(_ lhs: JobWorkspace, _ rhs: JobWorkspace) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.company == rhs.company
            && lhs.role == rhs.role
            && lhs.status == rhs.status
            && lhs.tags == rhs.tags
            && lhs.jobDescriptionSummary == rhs.jobDescriptionSummary
            && lhs.notes == rhs.notes
    }

    /// Keeps what is being typed and takes only the fields the form does
    /// not edit from the incoming snapshot.
    static func absorbingStoreOwnedFields(from incoming: JobWorkspace, into draft: JobWorkspace) -> JobWorkspace {
        var merged = draft
        merged.isArchived = incoming.isArchived
        merged.folderPath = incoming.folderPath
        merged.folderBookmark = incoming.folderBookmark
        merged.lastOpenedAt = incoming.lastOpenedAt
        merged.updatedAt = incoming.updatedAt
        return merged
    }
}

/// Tags are typed as one comma separated line and stored as a list.
enum WorkspaceTagsCodec {
    static func encode(_ tags: [String]) -> String {
        tags.joined(separator: ", ")
    }

    static func decode(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
