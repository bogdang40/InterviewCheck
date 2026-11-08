import Foundation

/// InterviewCheck://billing/<status> links the browser return page fires.
enum AccessDeepLink: Equatable {
    case billingSuccess
    case billingCancel
    case billingPortal

    static let scheme = AppBrand.urlScheme

    static func parse(_ url: URL) -> AccessDeepLink? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "billing" else { return nil }
        switch url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() {
        case "success": return .billingSuccess
        case "cancel": return .billingCancel
        case "portal": return .billingPortal
        default: return nil
        }
    }
}
