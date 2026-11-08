import AppKit

extension ScreenshotService {
    func acceptsCapture(_ identity: ScreenshotCaptureState.Identity) -> Bool {
        identity.sessionID == sessionIdentityProvider() && captureState.isCurrent(identity)
    }

    func publishCaptureError(_ error: ScreenshotError?, identity: ScreenshotCaptureState.Identity) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.acceptsCapture(identity) else { return }
            self.lastError = error
        }
    }

    func publishManualScreenshot(_ screenshot: Screenshot, identity: ScreenshotCaptureState.Identity) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.acceptsCapture(identity) else { return }
            self.lastError = nil
            self.screenshots.append(screenshot)
            self.manualCaptureRecorder(screenshot, identity.sessionID)
            self.logDebug("Screenshot captured successfully (\(self.screenshots.count) total)")
        }
    }

    static func recordManualCapture(_ screenshot: Screenshot, sessionID: UUID) {
        let controller = SessionController.shared
        guard controller.session.id == sessionID else { return }
        controller.persistManualScreenshots(ScreenshotService.shared.screenshots, capturedSessionID: sessionID)
        SessionLogger.shared.logScreenshot(
            sessionId: sessionID.uuidString,
            width: Int(screenshot.image.size.width),
            height: Int(screenshot.image.size.height),
            source: "manual"
        )
        guard SettingsManager.shared.sessionReplayStorageEnabled,
              let encrypted = SessionSnapshotCipher.encryptSnapshot(screenshot.image) else { return }
        SessionLogger.shared.saveSessionSnapshot(
            SessionSnapshotRecord(
                id: UUID().uuidString,
                sessionId: sessionID.uuidString,
                capturedAt: screenshot.capturedAt,
                width: encrypted.width,
                height: encrypted.height,
                sizeBytes: encrypted.payload.count,
                source: "manual",
                contentHash: encrypted.hash,
                encryptedPayload: encrypted.payload
            )
        )
    }
}
