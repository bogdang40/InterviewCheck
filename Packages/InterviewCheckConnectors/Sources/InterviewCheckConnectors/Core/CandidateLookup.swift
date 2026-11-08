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

/// A résumé found outside the ATS (an email attachment), saved to a file.
public struct FoundResume: Equatable, Sendable {
    public var file: URL
    public var filename: String
    /// Where it came from, in words ("Sam Recruiter <sam@acme.com>, Nov 6").
    public var origin: String

    public init(file: URL, filename: String, origin: String) {
        self.file = file
        self.filename = filename
        self.origin = origin
    }
}

/// Finds a candidate's résumé somewhere other than the ATS.
public protocol ResumeFinder: Connector {
    func findResume(for candidate: ExternalCandidate, into folder: URL) async throws -> FoundResume?
}
