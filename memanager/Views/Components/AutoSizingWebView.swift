import WebKit

final class AutoSizingWebView: WKWebView {
    var contentHeight: CGFloat = 300 {
        didSet {
            if abs(oldValue - contentHeight) > 1 {
                invalidateIntrinsicContentSize()
            }
        }
    }
    
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }
}
