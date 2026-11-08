import Foundation

/// Sizing rule shared by the two column overlay screens (Workspaces,
/// Knowledge): the list keeps a readable width and yields the rest to the
/// detail pane as the overlay is resized.
enum OverlayColumnWidth {
    static let minimumList: CGFloat = 250
    static let maximumList: CGFloat = 320
    static let listFraction: CGFloat = 0.30

    static func list(for containerWidth: CGFloat) -> CGFloat {
        min(maximumList, max(minimumList, containerWidth * listFraction))
    }
}
