import Foundation

/// Outlook and Exchange write Windows zone names in invites
/// (`TZID=Pacific Standard Time`). The common ones mapped to IANA ids, from
/// the CLDR windowsZones table.
enum WindowsTimeZones {
    static let iana: [String: String] = [
        "Dateline Standard Time": "Etc/GMT+12", "Hawaiian Standard Time": "Pacific/Honolulu",
        "Alaskan Standard Time": "America/Anchorage", "Pacific Standard Time": "America/Los_Angeles",
        "Pacific Standard Time (Mexico)": "America/Tijuana", "US Mountain Standard Time": "America/Phoenix",
        "Mountain Standard Time": "America/Denver", "Mountain Standard Time (Mexico)": "America/Mazatlan",
        "Central Standard Time": "America/Chicago", "Central Standard Time (Mexico)": "America/Mexico_City",
        "Canada Central Standard Time": "America/Regina", "Central America Standard Time": "America/Guatemala",
        "Eastern Standard Time": "America/New_York", "US Eastern Standard Time": "America/Indianapolis",
        "Eastern Standard Time (Mexico)": "America/Cancun", "SA Pacific Standard Time": "America/Bogota",
        "Atlantic Standard Time": "America/Halifax", "Venezuela Standard Time": "America/Caracas",
        "SA Western Standard Time": "America/La_Paz", "Pacific SA Standard Time": "America/Santiago",
        "Newfoundland Standard Time": "America/St_Johns", "E. South America Standard Time": "America/Sao_Paulo",
        "Argentina Standard Time": "America/Buenos_Aires", "UTC": "Etc/UTC", "Coordinated Universal Time": "Etc/UTC",
        "GMT Standard Time": "Europe/London", "Greenwich Standard Time": "Atlantic/Reykjavik",
        "W. Europe Standard Time": "Europe/Berlin", "Central Europe Standard Time": "Europe/Budapest",
        "Romance Standard Time": "Europe/Paris", "Central European Standard Time": "Europe/Warsaw",
        "W. Central Africa Standard Time": "Africa/Lagos", "GTB Standard Time": "Europe/Bucharest",
        "E. Europe Standard Time": "Europe/Chisinau", "FLE Standard Time": "Europe/Kiev",
        "Israel Standard Time": "Asia/Jerusalem", "Egypt Standard Time": "Africa/Cairo",
        "South Africa Standard Time": "Africa/Johannesburg", "Turkey Standard Time": "Europe/Istanbul",
        "Russian Standard Time": "Europe/Moscow", "Arabic Standard Time": "Asia/Baghdad",
        "Arab Standard Time": "Asia/Riyadh", "E. Africa Standard Time": "Africa/Nairobi",
        "Iran Standard Time": "Asia/Tehran", "Arabian Standard Time": "Asia/Dubai",
        "Pakistan Standard Time": "Asia/Karachi", "India Standard Time": "Asia/Calcutta",
        "Sri Lanka Standard Time": "Asia/Colombo", "Nepal Standard Time": "Asia/Katmandu",
        "Bangladesh Standard Time": "Asia/Dhaka", "SE Asia Standard Time": "Asia/Bangkok",
        "China Standard Time": "Asia/Shanghai", "Singapore Standard Time": "Asia/Singapore",
        "Taipei Standard Time": "Asia/Taipei", "W. Australia Standard Time": "Australia/Perth",
        "Tokyo Standard Time": "Asia/Tokyo", "Korea Standard Time": "Asia/Seoul",
        "Cen. Australia Standard Time": "Australia/Adelaide", "AUS Central Standard Time": "Australia/Darwin",
        "E. Australia Standard Time": "Australia/Brisbane", "AUS Eastern Standard Time": "Australia/Sydney",
        "New Zealand Standard Time": "Pacific/Auckland",
    ]

    static func zone(_ name: String) -> TimeZone? {
        TimeZone(identifier: name) ?? iana[name].flatMap(TimeZone.init(identifier:))
    }
}
