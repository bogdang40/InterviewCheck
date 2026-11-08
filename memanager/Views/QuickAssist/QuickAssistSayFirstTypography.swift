import SwiftUI

/// Keeps the opener the largest text on the stage. The display role wins
/// until the user's body size gets close to it, then the opener scales
/// with the body so it never reads smaller than the beats.
enum QuickAssistSayFirstTypography {
    static let displaySize: CGFloat = 36
    static let compactDisplaySize: CGFloat = 26
    static let leadOverBody: CGFloat = 6

    static func pointSize(bodyFontSize: CGFloat, availableWidth: CGFloat = 760) -> CGFloat {
        max(availableWidth < 520 ? compactDisplaySize : displaySize, bodyFontSize + leadOverBody)
    }

    static func font(bodyFontSize: CGFloat, availableWidth: CGFloat) -> Font {
        let size = pointSize(bodyFontSize: bodyFontSize, availableWidth: availableWidth)
        return OverlayType.body(size).weight(.semibold)
    }
}
