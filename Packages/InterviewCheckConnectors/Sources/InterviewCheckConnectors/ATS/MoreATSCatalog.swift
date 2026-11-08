import Foundation

/// Catalog entries for the other applicant tracking systems.
enum MoreATSCatalog {
    static func descriptor(_ kind: ConnectorKind) -> ConnectorDescriptor {
        let key = CredentialField("apiKey", "API key", secret: true)
        let viaCalendar = " Its API has no interview schedule: interviews come from your calendar, and Prepare finds the candidate here by email."
        switch kind {
        case .smartRecruiters:
            return ConnectorCatalog.entry(kind, "SmartRecruiters", .ats, "Interviews of candidates in the Interview step, job ads, r\u{00E9}sum\u{00E9}s and notes.",
                                          .fields([CredentialField("clientID", "OAuth client ID", optional: true),
                                                   CredentialField("clientSecret", "OAuth client secret", secret: true, optional: true),
                                                   CredentialField("apiKey", "Or an API key", secret: true, optional: true)]),
                                          [.upcomingInterviews, .candidates, .resumes, .jobDescriptions, .notes],
                                          setup: "Settings \u{203A} Application Management \u{203A} Credential Manager: create an OAuth client (scopes candidates_read, jobs_read, interviews_read, messages_write) or an API key. SmartRecruiters notes are shared messages, not private notes.",
                                          docs: "https://developers.smartrecruiters.com/docs/authentication")
        case .bambooHR:
            return ConnectorCatalog.entry(kind, "BambooHR", .ats, "Applicants and r\u{00E9}sum\u{00E9}s from BambooHR Hiring, and comments.",
                                          .fields([CredentialField("subdomain", "Company subdomain", placeholder: "acme"), key]),
                                          [.candidates, .resumes, .notes],
                                          setup: "Your name (lower left) \u{203A} API Keys \u{203A} Add New Key, from a user with hiring settings access." + viaCalendar,
                                          docs: "https://documentation.bamboohr.com/reference/applicant-tracking")
        case .teamtailor:
            return ConnectorCatalog.entry(kind, "Teamtailor", .ats, "Job ads, candidates, r\u{00E9}sum\u{00E9}s and notes.",
                                          .fields([CredentialField("apiKey", "Admin API key", secret: true),
                                                   CredentialField("userID", "Your user ID (for notes)", optional: true),
                                                   CredentialField("region", "Region", placeholder: "eu (default) or na", optional: true)]),
                                          [.candidates, .resumes, .jobDescriptions, .notes],
                                          setup: "Settings \u{203A} Integrations \u{203A} API keys: create an Admin key (read/write for notes)." + viaCalendar,
                                          docs: "https://docs.teamtailor.com/")
        case .recruitee:
            return ConnectorCatalog.entry(kind, "Recruitee", .ats, "Your upcoming interview events, candidates, r\u{00E9}sum\u{00E9}s, job offers and notes.",
                                          .fields([CredentialField("companyID", "Company ID"), CredentialField("apiKey", "Personal API token", secret: true)]),
                                          [.upcomingInterviews, .candidates, .resumes, .jobDescriptions, .notes],
                                          setup: "Settings \u{203A} Apps and plugins \u{203A} Personal API tokens \u{203A} Add new token. The company ID is shown on the same page. Notes are visible only to you.",
                                          docs: "https://docs.recruitee.com/reference/getting-started")
        case .jazzHR:
            return ConnectorCatalog.entry(kind, "JazzHR", .ats, "Jobs, applicants, r\u{00E9}sum\u{00E9}s and private notes.",
                                          .fields([key, CredentialField("userID", "Your user ID (for notes)", optional: true)]),
                                          [.candidates, .resumes, .jobDescriptions, .notes],
                                          setup: "Settings \u{203A} Integrations: copy the API key." + viaCalendar,
                                          docs: "https://www.resumatorapi.com/v1/")
        case .breezyHR:
            return ConnectorCatalog.entry(kind, "Breezy HR", .ats, "Positions, candidates, r\u{00E9}sum\u{00E9}s and team notes.",
                                          .fields([CredentialField("apiKey", "Personal access token", secret: true),
                                                   CredentialField("companyID", "Company ID", placeholder: "Optional: first company", optional: true)]),
                                          [.candidates, .resumes, .jobDescriptions, .notes],
                                          setup: "Profile icon \u{203A} My Settings \u{203A} create a personal access token (needs API access on your plan). Notes are team notes, never shown to candidates." + viaCalendar,
                                          docs: "https://developer.breezy.hr/")
        case .personio:
            return ConnectorCatalog.entry(kind, "Personio", .ats, "Recruiting candidates and jobs by name.",
                                          .fields([CredentialField("clientID", "Client ID"), CredentialField("clientSecret", "Client secret", secret: true)]),
                                          [.candidates],
                                          setup: "Settings \u{203A} Integrations \u{203A} API credentials: create credentials with Recruiting read. Personio's API has no interviews, r\u{00E9}sum\u{00E9}s, job texts or notes; use Kombo for more.",
                                          docs: "https://developer.personio.de/reference")
        case .zohoRecruit:
            return ConnectorCatalog.entry(kind, "Zoho Recruit", .ats, "Interviews, candidates, r\u{00E9}sum\u{00E9}s, job openings and notes.",
                                          .fields([CredentialField("domain", "Data centre", placeholder: "zoho.com, zoho.eu, zoho.in\u{2026}", optional: true),
                                                   CredentialField("clientID", "Client ID"), CredentialField("clientSecret", "Client secret", secret: true),
                                                   CredentialField("refreshToken", "Refresh token", secret: true)]),
                                          [.upcomingInterviews, .candidates, .resumes, .jobDescriptions, .notes],
                                          setup: "In api-console.zoho.com create a Self Client with scopes ZohoRecruit.modules.ALL, ZohoRecruit.search.READ, generate a code and exchange it for a refresh token, then paste the client ID, secret and refresh token.",
                                          docs: "https://www.zoho.com/recruit/developer-guide/apiv2/")
        case .workday:
            return ConnectorCatalog.entry(kind, "Workday Recruiting", .ats, "Through Merge or Kombo, which carry Workday interview times (Workday's own REST API leaves them out).",
                                          .fields([]), [.upcomingInterviews, .candidates, .jobDescriptions],
                                          setup: "Connect Merge or Kombo and link your Workday tenant there.", docs: "https://docs.merge.dev/integrations/ats/workday/")
        case .icims:
            return ConnectorCatalog.entry(kind, "iCIMS", .ats, "Through Unified.to, which reads iCIMS interviews; direct access needs an iCIMS partner licence.",
                                          .fields([]), [.upcomingInterviews, .candidates, .jobDescriptions],
                                          setup: "Connect Unified.to and authorize your iCIMS account there.", docs: "https://docs.unified.to/ats/interview")
        default:
            return ConnectorCatalog.entry(kind, kind.rawValue, .ats, "", .fields([]), [], setup: "")
        }
    }
}
