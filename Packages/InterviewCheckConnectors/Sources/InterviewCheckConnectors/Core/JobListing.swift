import Foundation

/// Lists open jobs (title, and the description when the list call has it),
/// so roles can be imported in one go.
public protocol JobListing: JobSource {
    func openJobs() async throws -> [ExternalJob]
}
