import AppKit

extension ScreenshotService {
    func captureFullScreenBase64() -> String? {
        captureFreshFullScreenBase64().base64
    }

    /// Permission and display selection stay on the caller's thread. The
    /// background work only captures, encodes, and commits through the cache.
    func prewarmFreshFullScreenCache() {
        guard !TestRuntime.isRunningUnitTests else { return }
        let identity = captureState.identity(sessionID: sessionIdentityProvider())
        guard let screen = NSScreen.main, let display = captureDisplay(for: screen),
              let request = captureState.beginCapture(for: identity, display: display, prewarm: true) else { return }
        guard checkPermission() else {
            captureState.finishCapture(request, base64: nil)
            return
        }
        let screenSize = screen.frame.size

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer { self.captureState.finishCapture(request, base64: nil) }
            guard self.captureState.isCurrent(identity) else { return }
            let capturedAt = Date()
            guard let cgImage = CGWindowListCreateImage(
                display.bounds,
                .optionOnScreenBelowWindow,
                kCGNullWindowID,
                [.boundsIgnoreFraming, .nominalResolution]
            ) else { return }
            let nsImage = NSImage(cgImage: cgImage, size: screenSize)
            guard let base64 = self.imageToCompressedBase64(nsImage) else { return }
            if self.captureState.finishCapture(request, base64: base64, capturedAt: capturedAt) {
                self.logDebug("Prewarmed fresh screenshot cache off the main thread")
            }
        }
    }

    func captureFreshFullScreenBase64() -> FreshCaptureResult {
        guard !TestRuntime.isRunningUnitTests else {
            return FreshCaptureResult(base64: nil, failureReason: .captureFailure)
        }
        let identity = captureState.identity(sessionID: sessionIdentityProvider())
        guard let screen = NSScreen.main, let display = captureDisplay(for: screen) else {
            publishCaptureError(.noScreen, identity: identity)
            return FreshCaptureResult(base64: nil, failureReason: .noScreen)
        }
        if let cached = captureState.cachedBase64(for: identity, display: display) {
            publishCaptureError(nil, identity: identity)
            return FreshCaptureResult(base64: cached, failureReason: nil)
        }

        guard checkPermission() else {
            logDebug("Screen recording permission denied for quick assist")
            publishCaptureError(.permissionDenied, identity: identity)
            openPermissionSettings()
            return FreshCaptureResult(base64: nil, failureReason: .permissionDenied)
        }
        guard let request = captureState.beginCapture(for: identity, display: display) else {
            return FreshCaptureResult(base64: nil, failureReason: .captureFailure)
        }
        defer { captureState.finishCapture(request, base64: nil) }
        let capturedAt = Date()
        guard let cgImage = CGWindowListCreateImage(
            display.bounds,
            .optionOnScreenBelowWindow,
            kCGNullWindowID,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            logDebug("CGWindowListCreateImage failed for quick assist")
            publishCaptureError(.captureFailure, identity: identity)
            return FreshCaptureResult(base64: nil, failureReason: .captureFailure)
        }
        let nsImage = NSImage(cgImage: cgImage, size: screen.frame.size)
        guard let base64 = imageToCompressedBase64(nsImage) else {
            publishCaptureError(.captureFailure, identity: identity)
            return FreshCaptureResult(base64: nil, failureReason: .captureFailure)
        }
        guard acceptsCapture(identity) else {
            return FreshCaptureResult(base64: nil, failureReason: .captureFailure)
        }
        captureState.finishCapture(request, base64: base64, capturedAt: capturedAt)
        publishCaptureError(nil, identity: identity)
        return FreshCaptureResult(base64: base64, failureReason: nil)
    }

    private func captureDisplay(for screen: NSScreen) -> ScreenshotCaptureState.Display? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let bounds = ScreenCaptureGeometry.displayRect(for: screen) else { return nil }
        return ScreenshotCaptureState.Display(id: number.uint32Value, bounds: bounds)
    }
}
