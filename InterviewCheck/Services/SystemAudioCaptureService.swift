import Foundation
import ScreenCaptureKit
import CoreMedia
import AppKit

final class SystemAudioCaptureService: NSObject {
    enum SystemAudioCaptureError: Error {
        case noDisplay
    }

    private let outputQueue = DispatchQueue(label: "SystemAudioCapture.Output")
    private let streamOutput = SystemAudioStreamOutput()
    private var stream: SCStream?
    private(set) var isRunning = false
    private(set) var activeDisplayID: CGDirectDisplayID?

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    func start() async throws {
        guard !isRunning else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainDisplayID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first
        guard let display = display else {
            throw SystemAudioCaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48000
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        streamOutput.onSampleBuffer = { [weak self] sampleBuffer in
            self?.onSampleBuffer?(sampleBuffer)
        }

        try stream.addStreamOutput(streamOutput, type: SCStreamOutputType.audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()

        self.stream = stream
        activeDisplayID = display.displayID
        isRunning = true
    }

    func stop() async {
        guard isRunning else { return }
        do {
            try await stream?.stopCapture()
        } catch {
            onError?(error)
        }
        stream = nil
        activeDisplayID = nil
        isRunning = false
    }

    func restart() async throws {
        if isRunning {
            await stop()
        }
        try await start()
    }
}

private final class SystemAudioStreamOutput: NSObject, SCStreamOutput {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        onSampleBuffer?(sampleBuffer)
    }
}

extension SystemAudioCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}
