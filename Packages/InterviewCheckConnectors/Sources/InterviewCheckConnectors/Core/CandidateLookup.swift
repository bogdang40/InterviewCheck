import Foundation

/// A candidate found in an ATS, with the job of their latest application.
public struct CandidateMatch: Equatable, Sendable {
    public var candidate: ExternalCandidate
    public var job: ExternalJob?
    public var applicationID: String?

    public init(candidate: ExternalCandidate, job: ExternalJob? = nil, applicationID: String? = nil) {
        self.candidate = candidate
        self.job = job
        self.applicationID = applicationID
    }
}

/// Finds a candidate by email, so an interview from a calendar invite can
/// be filled with the job description and résumé from the ATS.
public protocol CandidateLookup: Connector {
    func findCandidate(email: String) async throws -> CandidateMatch?
}
