import Foundation

/// Builds a connector from its kind and saved credentials.
public enum ConnectorFactory {
    /// Kinds with a working implementation in this build.
    public static let implemented: Set<ConnectorKind> = {
        Set(ConnectorKind.allCases.filter { kind in
            (try? make(kind, credentials: ConnectorCredentials(fields: ["apiKey": "x", "subdomain": "x", "companyID": "x",
                                                                        "accountToken": "x", "integrationID": "x", "url": "https://x",
                                                                        "clientID": "x", "clientSecret": "x", "domain": "zoho.com",
                                                                        "email": "x", "password": "x", "appID": "x",
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
        nil
    }
}
