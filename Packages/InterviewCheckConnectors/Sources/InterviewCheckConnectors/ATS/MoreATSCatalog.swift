import Foundation

/// Catalog entries for the other applicant tracking systems.
enum MoreATSCatalog {
    static func descriptor(_ kind: ConnectorKind) -> ConnectorDescriptor {
        let key = CredentialField("apiKey", "API key", secret: true)
        switch kind {
        case .smartRecruiters:
            return ConnectorCatalog.entry(kind, "SmartRecruiters", .ats, "Interviews, candidates, r\u{00E9}sum\u{00E9}s and job ads.",
                                          .fields([key]), [.upcomingInterviews, .candidates, .resumes, .jobDescriptions, .notes],
                                          setup: "SmartRecruiters \u{203A} Settings \u{203A} Apps & Integrations \u{203A} API key.",
                                          docs: "https://developers.smartrecruiters.com/")
        case .bambooHR:
            return ConnectorCatalog.entry(kind, "BambooHR", .ats, "Job openings and applicants from BambooHR Hiring.",
                                          .fields([CredentialField("subdomain", "Company subdomain", placeholder: "acme"), key]),
                                          [.jobDescriptions, .candidates, .resumes],
                                          setup: "BambooHR \u{203A} your name \u{203A} API Keys \u{203A} Add New Key.",
                                          docs: "https://documentation.bamboohr.com/")
        case .teamtailor:
            return ConnectorCatalog.entry(kind, "Teamtailor", .ats, "Jobs, candidates and interviews.",
                                          .fields([key]), [.upcomingInterviews, .candidates, .jobDescriptions],
                                          setup: "Teamtailor \u{203A} Settings \u{203A} Integrations \u{203A} API keys \u{203A} New (Read).",
                                          docs: "https://docs.teamtailor.com/")
        case .recruitee:
            return ConnectorCatalog.entry(kind, "Recruitee", .ats, "Interview events, candidates and job offers.",
                                          .fields([CredentialField("companyID", "Company ID"), key]),
                                          [.upcomingInterviews, .candidates, .resumes, .jobDescriptions, .notes],
                                          setup: "Recruitee \u{203A} Settings \u{203A} Apps and plugins \u{203A} Personal API tokens.",
                                          docs: "https://docs.recruitee.com/reference")
        case .jazzHR:
            return ConnectorCatalog.entry(kind, "JazzHR", .ats, "Jobs and applicants.",
                                          .fields([key]), [.jobDescriptions, .candidates],
                                          setup: "JazzHR \u{203A} Settings \u{203A} Integrations \u{203A} API key.",
                                          docs: "https://www.resumatorapi.com/v1/")
        case .breezyHR:
            return ConnectorCatalog.entry(kind, "Breezy HR", .ats, "Positions and candidates.",
                                          .fields([CredentialField("email", "Breezy email"), CredentialField("password", "Password", secret: true)]),
                                          [.jobDescriptions, .candidates, .resumes],
                                          setup: "Sign in with a Breezy HR user that can see the positions you interview for.",
                                          docs: "https://developer.breezy.hr/")
        case .personio:
            return ConnectorCatalog.entry(kind, "Personio", .ats, "Recruiting applications and job positions.",
                                          .fields([CredentialField("clientID", "Client ID"), CredentialField("clientSecret", "Client secret", secret: true)]),
                                          [.candidates, .jobDescriptions],
                                          setup: "Personio \u{203A} Settings \u{203A} Integrations \u{203A} API credentials \u{203A} Generate (Recruiting read).",
                                          docs: "https://developer.personio.de/")
        case .zohoRecruit:
            return ConnectorCatalog.entry(kind, "Zoho Recruit", .ats, "Interviews, candidates and job openings.",
                                          .fields([CredentialField("domain", "Data centre", placeholder: "zoho.com"), key]),
                                          [.upcomingInterviews, .candidates, .jobDescriptions],
                                          setup: "Create a self client in the Zoho API console and paste its access token.",
                                          docs: "https://www.zoho.com/recruit/developer-guide/apiv2/")
        case .workday:
            return ConnectorCatalog.entry(kind, "Workday Recruiting", .ats, "Through a unified API (Merge or Kombo), which handles Workday's tenant setup.",
                                          .fields([]), [.upcomingInterviews, .candidates, .jobDescriptions],
                                          setup: "Connect Merge or Kombo and link your Workday tenant there.", docs: "https://www.merge.dev/integrations/workday")
        case .icims:
            return ConnectorCatalog.entry(kind, "iCIMS", .ats, "Through a unified API (Merge or Kombo); iCIMS needs a partner agreement for direct access.",
                                          .fields([]), [.upcomingInterviews, .candidates, .jobDescriptions],
                                          setup: "Connect Merge or Kombo and link your iCIMS account there.", docs: "https://www.merge.dev/integrations/icims")
        default:
            return ConnectorCatalog.entry(kind, kind.rawValue, .ats, "", .fields([]), [], setup: "")
        }
    }
}
