import Foundation

/// A person on the other side of a connector (interviewer, organiser).
public struct ExternalPerson: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var email: String?

    public init(name: String, email: String? = nil) {
        self.name = name
        self.email = email
    }
}

/// A file a connector can download (résumé, recording, transcript).
public struct ExternalFile: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case resume, audio, video, transcript, other }

    public var kind: Kind
    public var filename: String
    public var url: URL
    /// The URL needs the connector's credentials (otherwise it is signed).
    public var needsAuth: Bool

    public init(kind: Kind, filename: String, url: URL, needsAuth: Bool) {
        self.kind = kind
        self.filename = filename
        self.url = url
        self.needsAuth = needsAuth
    }
}

/// A candidate as the source system knows them.
public struct ExternalCandidate: Codable, Equatable, Hashable, Sendable {
    public var externalID: String?
    public var name: String
    public var email: String?
    public var resume: ExternalFile?
    /// The candidate's page in the source system, for "Open in Greenhouse".
    public var profileURL: URL?

    public init(externalID: String? = nil, name: String, email: String? = nil, resume: ExternalFile? = nil,
                profileURL: URL? = nil) {
        self.externalID = externalID
        self.name = name
        self.email = email
        self.resume = resume
        self.profileURL = profileURL
    }
}

/// A job: its title and, when fetched, the full description as plain text.
public struct ExternalJob: Codable, Equatable, Hashable, Sendable {
    public var externalID: String
    public var title: String
    public var company: String?
    public var description: String

    public init(externalID: String, title: String, company: String? = nil, description: String = "") {
        self.externalID = externalID
        self.title = title
        self.company = company
        self.description = description
    }
}

/// One scheduled interview from an ATS, a calendar or an invite.
public struct ExternalInterview: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var source: ConnectorKind
    public var externalID: String
    public var title: String
    public var startsAt: Date
    public var endsAt: Date?
    public var meetingURL: URL?
    public var candidate: ExternalCandidate?
    public var job: ExternalJob?
    public var applicationID: String?
    public var interviewers: [ExternalPerson]

    /// Stable across syncs: the source plus its own id.
    public var id: String { "\(source.rawValue):\(externalID)" }

    public init(source: ConnectorKind, externalID: String, title: String, startsAt: Date, endsAt: Date? = nil,
                meetingURL: URL? = nil, candidate: ExternalCandidate? = nil, job: ExternalJob? = nil,
                applicationID: String? = nil, interviewers: [ExternalPerson] = []) {
        self.source = source
        self.externalID = externalID
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.meetingURL = meetingURL
        self.candidate = candidate
        self.job = job
        self.applicationID = applicationID
        self.interviewers = interviewers
    }
}

/// A finished meeting's recording and/or transcript.
public struct ExternalRecording: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var source: ConnectorKind
    public var externalID: String
    public var title: String
    public var startedAt: Date
    public var duration: TimeInterval?
    public var meetingURL: URL?
    public var files: [ExternalFile]

    public var id: String { "\(source.rawValue):\(externalID)" }

    /// The smallest file worth analysing: audio first, then video.
    public var bestMediaFile: ExternalFile? {
        files.first { $0.kind == .audio } ?? files.first { $0.kind == .video }
    }

    public init(source: ConnectorKind, externalID: String, title: String, startedAt: Date,
                duration: TimeInterval? = nil, meetingURL: URL? = nil, files: [ExternalFile]) {
        self.source = source
        self.externalID = externalID
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.meetingURL = meetingURL
        self.files = files
    }
}
