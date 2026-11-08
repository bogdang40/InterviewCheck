import Foundation

public enum ConnectorCategory: String, Codable, CaseIterable, Sendable {
    // In the order the Connections list shows them: no-setup sources first.
    case calendar, meetings, ats, mcp, unified

    public var title: String {
        switch self {
        case .ats: return "Applicant tracking"
        case .unified: return "Unified HR APIs (Workday, iCIMS, SuccessFactors and more)"
        case .calendar: return "Calendars"
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
    case greenhouseMCP, ashbyMCP, workableMCP, mcp

    public var id: String { rawValue }
    public var descriptor: ConnectorDescriptor { ConnectorCatalog.descriptor(self) }

    /// Systems reached through a unified API rather than directly.
    public var routedThrough: [ConnectorKind] {
        switch self {
        case .workday: return [.merge, .kombo]
        case .icims: return [.unifiedTo]
        default: return []
        }
    }
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
    /// An on/off switch stored as "true" or empty.
    public var isToggle: Bool

    public init(_ key: String, _ label: String, placeholder: String = "", secret: Bool = false, optional: Bool = false,
                toggle: Bool = false) {
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.isSecret = secret
        self.isOptional = optional || toggle
        self.isToggle = toggle
    }
}

public enum ConnectorAuth: Equatable, Sendable {
    /// MCP sign-in: the server's OAuth details are discovered at sign-in.
    case mcp
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

    /// The vendor's name without a note in brackets ("Greenhouse").
    public var vendorName: String {
        name.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
    }
}
