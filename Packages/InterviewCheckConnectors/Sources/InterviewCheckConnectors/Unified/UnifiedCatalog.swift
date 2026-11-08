import Foundation

/// Unified ATS APIs: one connection reaches dozens of systems.
enum UnifiedCatalog {
    static func descriptor(_ kind: ConnectorKind) -> ConnectorDescriptor {
        switch kind {
        case .merge:
            return ConnectorCatalog.entry(kind, "Merge", .unified, "Workday, iCIMS, SuccessFactors, Taleo, Jobvite, Greenhouse, Lever and 40+ more through one API.",
                                          .fields([CredentialField("apiKey", "Production access key", secret: true),
                                                   CredentialField("accountToken", "Linked account token", secret: true)]),
                                          [.upcomingInterviews, .candidates, .resumes, .jobDescriptions, .notes],
                                          setup: "In Merge, link your ATS with Merge Link and copy the account token for it.",
                                          docs: "https://docs.merge.dev/ats/overview/")
        case .kombo:
            return ConnectorCatalog.entry(kind, "Kombo", .unified, "Workday, SuccessFactors, iCIMS, Personio, Teamtailor and 50+ more through one API.",
                                          .fields([CredentialField("apiKey", "API key", secret: true),
                                                   CredentialField("integrationID", "Integration ID")]),
                                          [.upcomingInterviews, .candidates, .jobDescriptions],
                                          setup: "In Kombo, connect your ATS and copy the integration ID.", docs: "https://docs.kombo.dev/")
        case .apideck:
            return ConnectorCatalog.entry(kind, "Apideck", .unified, "Jobs and applicants from many ATSs through one API.",
                                          .fields([CredentialField("apiKey", "API key", secret: true), CredentialField("appID", "App ID"),
                                                   CredentialField("consumerID", "Consumer ID"), CredentialField("serviceID", "Service ID", optional: true)]),
                                          [.candidates, .jobDescriptions],
                                          setup: "In Apideck Vault, connect your ATS for a consumer and copy the IDs.", docs: "https://developers.apideck.com/apis/ats/reference")
        case .unifiedTo:
            return ConnectorCatalog.entry(kind, "Unified.to", .unified, "Jobs, candidates and interviews from many ATSs through one API.",
                                          .fields([CredentialField("apiKey", "API token", secret: true), CredentialField("connectionID", "Connection ID")]),
                                          [.upcomingInterviews, .candidates, .jobDescriptions],
                                          setup: "In Unified.to, authorize your ATS and copy the connection ID.", docs: "https://docs.unified.to/")
        default:
            return ConnectorCatalog.entry(kind, kind.rawValue, .unified, "", .fields([]), [], setup: "")
        }
    }
}
