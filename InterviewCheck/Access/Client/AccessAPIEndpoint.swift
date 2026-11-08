import Foundation

/// Builds URLRequests for the access server. Nothing here performs IO.
struct AccessAPIEndpoint {
    enum Method: String {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
    }

    let path: String
    let method: Method
    var query: [URLQueryItem] = []
    var body: [String: Any]? = nil
    var requiresAuth = true

    static func signup(email: String, password: String, deviceName: String, adminSecret: String?) -> AccessAPIEndpoint {
        var body: [String: Any] = ["email": email, "password": password, "deviceName": deviceName]
        if let adminSecret, !adminSecret.isEmpty { body["adminSecret"] = adminSecret }
        return AccessAPIEndpoint(path: "/v1/auth/signup", method: .post, body: body, requiresAuth: false)
    }

    static func login(email: String, password: String, deviceName: String) -> AccessAPIEndpoint {
        AccessAPIEndpoint(path: "/v1/auth/login", method: .post, body: ["email": email, "password": password, "deviceName": deviceName], requiresAuth: false)
    }

    static let logout = AccessAPIEndpoint(path: "/v1/auth/logout", method: .post)
    static let me = AccessAPIEndpoint(path: "/v1/me", method: .get)
    static let plans = AccessAPIEndpoint(path: "/v1/billing/plans", method: .get, requiresAuth: false)
    static func checkout(plan: String) -> AccessAPIEndpoint {
        AccessAPIEndpoint(path: "/v1/billing/checkout", method: .post, body: ["plan": plan])
    }
    static let portal = AccessAPIEndpoint(path: "/v1/billing/portal", method: .post)

    static let adminStats = AccessAPIEndpoint(path: "/v1/admin/stats", method: .get)
    static func adminUsers(query: String?, cursor: String?, limit: Int = 50) -> AccessAPIEndpoint {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return AccessAPIEndpoint(path: "/v1/admin/users", method: .get, query: items)
    }
    static func adminPatch(userID: String, patch: AdminUserPatch) -> AccessAPIEndpoint {
        AccessAPIEndpoint(path: "/v1/admin/users/\(userID)", method: .patch, body: patch.jsonObject())
    }
    static func adminAudit(limit: Int = 100) -> AccessAPIEndpoint {
        AccessAPIEndpoint(path: "/v1/admin/audit", method: .get, query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    /// Only unreserved characters pass through, so `+` (a space to form
    /// style decoders) and `&` inside a value cannot change the query.
    static let queryValueAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    static func percentEncoded(_ item: URLQueryItem) -> URLQueryItem {
        URLQueryItem(
            name: item.name.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? item.name,
            value: item.value?.addingPercentEncoding(withAllowedCharacters: queryValueAllowed)
        )
    }

    func makeRequest(baseURL: URL, token: String?) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw AccessAPIError.invalidServerURL(baseURL.absoluteString)
        }
        if !query.isEmpty { components.percentEncodedQueryItems = query.map(AccessAPIEndpoint.percentEncoded) }
        guard let url = components.url else { throw AccessAPIError.invalidServerURL(baseURL.absoluteString) }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("InterviewCheck-macos/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        if requiresAuth {
            guard let token, !token.isEmpty else { throw AccessAPIError.unauthenticated }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
