import Foundation

/// Unified ATS APIs: one connection reaches dozens of systems. Each needs
/// the company's own account with the vendor (the key stays in the Keychain).
enum UnifiedCatalog {
    static let region = CredentialField("region", "Region", placeholder: "Leave empty for US", optional: true)

    static func descriptor(_ kind: ConnectorKind) -> ConnectorDescriptor {
        switch kind {
        case .merge:
            return ConnectorCatalog.entry(kind, "Merge", .unified, "Workday, SAP SuccessFactors, Oracle Taleo, SmartRecruiters and 60+ more ATSs through one API.",
                                          .fields([CredentialField("apiKey", "Production access key", secret: true),
                                                   CredentialField("accountToken", "Linked account token", secret: true),
                                                   CredentialField("remoteUserID", "Your ATS user ID (for notes)", optional: true),
                                                   CredentialField("region", "Region", placeholder: "us, eu or ap", optional: true)]),
                                          [.upcomingInterviews, .candidates, .resumes, .jobDescriptions, .notes],
                                          setup: "Needs a Merge account. Link your ATS with Merge Link (or a Magic Link) and paste the API key and that linked account's token. Interviews come from Workday, SuccessFactors, Taleo, Greenhouse, Lever, Ashby and others; Merge's entry plan syncs once a day.",
                                          docs: "https://docs.merge.dev/ats/interviews/")
        case .kombo:
            return ConnectorCatalog.entry(kind, "Kombo", .unified, "Workday, SAP SuccessFactors, SmartRecruiters, Personio, HiBob and 100+ more through one API.",
                                          .fields([CredentialField("apiKey", "API key", secret: true),
                                                   CredentialField("integrationID", "Integration ID"),
                                                   CredentialField("region", "Region", placeholder: "eu (default), us or ca", optional: true)]),
                                          [.upcomingInterviews, .candidates, .resumes, .jobDescriptions, .notes],
                                          setup: "Needs a Kombo account. Connect your ATS with Kombo Connect and paste the API key and integration ID. Interviews come with the candidate and job in one call; data refreshes about every three hours.",
                                          docs: "https://docs.kombo.dev/ats/v1/get-interviews")
        case .apideck:
            return ConnectorCatalog.entry(kind, "Apideck", .unified, "Job descriptions and applicants from Greenhouse, Lever, Workday, SuccessFactors, Teamtailor and more.",
                                          .fields([CredentialField("apiKey", "API key", secret: true), CredentialField("appID", "App ID"),
                                                   CredentialField("consumerID", "Consumer ID"),
                                                   CredentialField("serviceID", "Service ID", placeholder: "e.g. greenhouse", optional: true)]),
                                          [.candidates, .resumes, .jobDescriptions],
                                          setup: "Needs an Apideck account. Authorize your ATS in Apideck Vault for a consumer and paste the IDs. Apideck has no interview schedule, so pair it with your calendar.",
                                          docs: "https://developers.apideck.com/apis/ats/reference")
        case .unifiedTo:
            return ConnectorCatalog.entry(kind, "Unified.to", .unified, "iCIMS, Jobvite, Workday, SmartRecruiters, Oracle Taleo BE and 180+ ATSs, read live.",
                                          .fields([CredentialField("apiKey", "Workspace API token", secret: true),
                                                   CredentialField("connectionID", "Connection ID"),
                                                   CredentialField("region", "Region", placeholder: "us, eu or au", optional: true)]),
                                          [.upcomingInterviews, .candidates, .resumes, .jobDescriptions, .notes],
                                          setup: "Needs a Unified.to account. Authorize your ATS there and paste the workspace token and connection ID. Live data; Workday interviews come without times, so use Merge or Kombo for Workday.",
                                          docs: "https://docs.unified.to/ats/interview")
        default:
            return ConnectorCatalog.entry(kind, kind.rawValue, .unified, "", .fields([]), [], setup: "")
        }
    }
}
