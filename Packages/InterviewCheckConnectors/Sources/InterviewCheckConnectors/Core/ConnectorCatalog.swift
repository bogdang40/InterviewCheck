import Foundation

public enum ConnectorCategory: String, Codable, CaseIterable, Sendable {
    case ats, unified, calendar, meetings, mcp

    public var title: String {
        switch self {
        case .ats: return "Applicant tracking"
        case .unified: return "Unified HR APIs (Workday, iCIMS, SuccessFactors and more)"
        case .calendar: return "Calendar and mail"
        case .meetings: return "Meeting recordings"
        case .mcp: return "MCP servers"
        }
    }
}

public enum ConnectorKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleCalendar, icsFile
    case google, microsoft365, zoom
    case greenhouse, lever, ashby, workable, smartRecruiters, bambooHR, teamtailor, recruitee, jazzHR, breezyHR
    case personio, zohoRecruit, workday, icims
    case merge, kombo, apideck, unifiedTo
    case mcp

    public var id: String { rawValue }
    public var descriptor: ConnectorDescriptor { ConnectorCatalog.descriptor(self) }
}

public enum ConnectorCapability: String, Codable, CaseIterable, Sendable {
    case upcomingInterviews, jobDescriptions, candidates, resumes, notes, recordings, transcripts, emailInvites

    public var title: String {
        switch self {
        case .upcomingInterviews: return "Upcoming interviews"
        case .jobDescriptions: return "Job descriptions"
        case .candidates: return "Candidates"
        case .resumes: return "R\u{00E9}sum\u{00E9}s"
        case .notes: return "Private notes back"
        case .recordings: return "Recordings"
        case .transcripts: return "Transcripts"
        case .emailInvites: return "Email invites"
        }
    }
}

/// One credential the user types in Settings.
public struct CredentialField: Equatable, Sendable {
    public var key: String
    public var label: String
    public var placeholder: String
    public var isSecret: Bool
    public var isOptional: Bool

    public init(_ key: String, _ label: String, placeholder: String = "", secret: Bool = false, optional: Bool = false) {
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.isSecret = secret
        self.isOptional = optional
    }
}

public enum ConnectorAuth: Equatable, Sendable {
    /// Fields typed in Settings (API keys, subdomains, account tokens).
    case fields([CredentialField])
    /// Browser sign-in; the fields are the OAuth app's client id/secret.
    case oauth(OAuthProvider, clientFields: [CredentialField])
    /// Uses macOS permissions (Calendar) or a picked file: no credentials.
    case system
}

public struct ConnectorDescriptor: Equatable, Sendable {
    public var kind: ConnectorKind
    public var name: String
    public var category: ConnectorCategory
    public var summary: String
    public var auth: ConnectorAuth
    public var capabilities: [ConnectorCapability]
    public var setup: String
    public var docsURL: URL?
    /// Built from the vendor's public docs; not yet run against a live account.
    public var isUntestedAgainstLiveAccount: Bool
}
