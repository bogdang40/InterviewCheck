import AppKit

/// Locates the NSScrollView a SwiftUI-embedded helper view belongs to:
/// the enclosing scroll view if AppKit already knows it, then the superview
/// chain, then a subtree search. Pure over the view hierarchy, unit tested
/// with constructed NSView trees.
enum EnclosingScrollViewLocator {
    static func locate(around view: NSView) -> NSScrollView? {
        if let enclosing = view.enclosingScrollView {
            return enclosing
        }
        if let fromSuperviews = findInSuperviewChain(from: view) {
            return fromSuperviews
        }
        return findInSubtree(from: view)
    }

    private static func findInSuperviewChain(from view: NSView) -> NSScrollView? {
        var current = view.superview
        while let node = current {
            if let scrollView = node as? NSScrollView {
                return scrollView
            }
            if let enclosing = node.enclosingScrollView {
                return enclosing
            }
            current = node.superview
        }
        return nil
    }

    private static func findInSubtree(from view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findInSubtree(from: subview) {
                return found
            }
        }
        return nil
    }
}
