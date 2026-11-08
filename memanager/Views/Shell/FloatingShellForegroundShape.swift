import SwiftUI

/// Clips retained foreground content to the three native pane interiors.
/// A screen's rectangular fill cannot cover a rounded corner or desktop gap.
struct FloatingShellForegroundShape: Shape {
    let geometry: FloatingShellGeometry

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (bounds, radius) in [(geometry.navigation, CGFloat(26)), (geometry.content, 26), (geometry.dock, 24)] {
            path.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: bounds))
        }
        return path
    }
}
