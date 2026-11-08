import Foundation

/// Builds a connector from its kind and saved credentials.
public enum ConnectorFactory {
    /// Kinds with a working implementation in this build.
    public static let implemented: Set<ConnectorKind> = {
        Set(ConnectorKind.allCases.filter { kind in
            (try? make(kind, credentials: ConnectorCredentials(fields: ["apiKey": "x", "subdomain": "x", "companyID": "x",
                                                                        "accountToken": "x", "integrationID": "x", "url": "https://x",
                                                                        "clientID": "x", "clientSecret": "x", "domain": "zoho.com",
                                                                        "email": "x", "password": "x", "appID": "x", "refreshToken": "x",
                                                                        "consumerID": "x", "connectionID": "x"]),
                           accessToken: { "x" })) != nil
        })
    }()

    public static func make(_ kind: ConnectorKind, credentials: ConnectorCredentials,
                            transport: HTTPTransport = URLSession.shared,
                            accessToken: AccessTokenProvider? = nil) throws -> Connector {
        switch kind {
        case .appleCalendar:
            return AppleCalendarConnector(extraKeywords: credentials["keywords"]?
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [])
        default:
            if let connector = try makeHTTP(kind, credentials: credentials, transport: transport, accessToken: accessToken) {
                return connector
            }
            throw ConnectorError.unsupported("\(kind.descriptor.name) is not available in this build yet.")
        }
    }

    /// Filled in by each connector family as it is added.
    static func makeHTTP(_ kind: ConnectorKind, credentials: ConnectorCredentials, transport: HTTPTransport,
                         accessToken: AccessTokenProvider?) throws -> Connector? {
        switch kind {
        case .greenhouse: return try GreenhouseConnector(credentials: credentials, transport: transport)
        case .lever: return try LeverConnector(credentials: credentials, transport: transport)
        case .ashby: return try AshbyConnector(credentials: credentials, transport: transport)
        case .workable: return try WorkableConnector(credentials: credentials, transport: transport)
        case .merge: return try MergeConnector(credentials: credentials, transport: transport)
        case .kombo: return try KomboConnector(credentials: credentials, transport: transport)
        case .unifiedTo: return try UnifiedToConnector(credentials: credentials, transport: transport)
        case .apideck: return try ApideckConnector(credentials: credentials, transport: transport)
        case .recruitee: return try RecruiteeConnector(credentials: credentials, transport: transport)
        case .zohoRecruit: return try ZohoRecruitConnector(credentials: credentials, transport: transport)
        case .smartRecruiters: return try SmartRecruitersConnector(credentials: credentials, transport: transport)
        case .teamtailor: return try TeamtailorConnector(credentials: credentials, transport: transport)
        case .bambooHR: return try BambooHRConnector(credentials: credentials, transport: transport)
        case .jazzHR: return try JazzHRConnector(credentials: credentials, transport: transport)
        case .breezyHR: return try BreezyConnector(credentials: credentials, transport: transport)
        case .personio: return try PersonioConnector(credentials: credentials, transport: transport)
        case .google: return try GoogleWorkspaceConnector(credentials: credentials, transport: transport, accessToken: accessToken)
        case .microsoft365: return try MicrosoftGraphConnector(credentials: credentials, transport: transport, accessToken: accessToken)
        case .zoom: return try ZoomMeetingsConnector(credentials: credentials, transport: transport, accessToken: accessToken)
        default: return nil
        }
    }
}
