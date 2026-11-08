import Foundation

extension SessionController {
    // MARK: - Context Image Assembly

    func stackedScreenshotsNewestToOldest() -> [String] {
        screenshotService
            .getBase64Images()
            .reversed()
            .filter { !$0.isEmpty }
    }
    func orderedScreenshots(
        freshCaptureResult: ScreenshotService.FreshCaptureResult,
        stackedScreenshots: [String]
    ) -> [String] {
        var ordered: [String] = []
        if let fresh = freshCaptureResult.base64, !fresh.isEmpty {
            ordered.append(fresh)
        }
        ordered.append(contentsOf: stackedScreenshots)
        return ordered
    }
    func buildContextEnvelope(
        freshCaptureResult: ScreenshotService.FreshCaptureResult,
        orderedScreenshots: [String]
    ) -> ContextEnvelope {
        let hasFresh = freshCaptureResult.base64 != nil
        let contextImages: [ContextImage] = orderedScreenshots.enumerated().map { index, base64 in
            let source: ContextImageSource = hasFresh && index == 0 ? .freshScreen : .capturedStack
            return ContextImage(source: source, base64: base64)
        }

        return ContextEnvelope(
            images: contextImages,
            freshCaptureStatus: hasFresh ? .success : .failed,
            freshCaptureFailureReason: freshCaptureResult.failureReason?.rawValue
        )
    }
    func captureFailureStatusMessage(for result: ScreenshotService.FreshCaptureResult) -> String? {
        guard let reason = result.failureReason else {
            return nil
        }
        switch reason {
        case .permissionDenied:
            return "Fresh screen capture failed (permissionDenied). Continuing with existing context."
        case .captureFailure:
            return "Fresh screen capture failed (captureFailure). Continuing with existing context."
        case .noScreen:
            return "Fresh screen capture failed (noScreen). Continuing with existing context."
        }
    }
}
