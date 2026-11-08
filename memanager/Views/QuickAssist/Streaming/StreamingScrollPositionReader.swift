import AppKit
import SwiftUI

struct StreamingScrollMetrics: Equatable {
    let offsetY: CGFloat
    let visibleHeight: CGFloat
    let contentHeight: CGFloat
}

/// Zero sized view that reports the enclosing NSScrollView's bounds so the
/// container can tell whether the reader is following the stream.
struct StreamingScrollPositionReader: NSViewRepresentable {
    let onMetricsChange: (StreamingScrollMetrics) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMetricsChange: onMetricsChange)
    }

    func makeNSView(context: Context) -> AttachingView {
        let view = AttachingView(frame: .zero)
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: AttachingView, context: Context) {
        context.coordinator.onMetricsChange = onMetricsChange
    }

    /// Binds the bounds change observer when the view attaches to a window.
    final class AttachingView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            attemptBind(allowRetry: true)
        }

        private func attemptBind(allowRetry: Bool) {
            guard window != nil, let coordinator else { return }
            if let scrollView = EnclosingScrollViewLocator.locate(around: self) {
                coordinator.bind(scrollView: scrollView)
                coordinator.emitMetrics()
            } else if allowRetry {
                DispatchQueue.main.async { [weak self] in
                    self?.attemptBind(allowRetry: false)
                }
            }
        }
    }

    final class Coordinator {
        var onMetricsChange: (StreamingScrollMetrics) -> Void

        private weak var scrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var previousMetrics: StreamingScrollMetrics?

        init(onMetricsChange: @escaping (StreamingScrollMetrics) -> Void) {
            self.onMetricsChange = onMetricsChange
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        func bind(scrollView: NSScrollView) {
            guard self.scrollView !== scrollView else { return }
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
                self.boundsObserver = nil
            }
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.emitMetrics()
            }
        }

        func emitMetrics() {
            guard let scrollView else { return }
            let metrics = StreamingScrollMetrics(
                offsetY: scrollView.contentView.bounds.origin.y,
                visibleHeight: scrollView.contentView.bounds.height,
                contentHeight: scrollView.documentView?.bounds.height ?? 0
            )
            guard previousMetrics != metrics else { return }
            previousMetrics = metrics
            onMetricsChange(metrics)
        }
    }
}
