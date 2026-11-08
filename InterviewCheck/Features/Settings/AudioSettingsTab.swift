import AVFoundation
import CoreGraphics
import SwiftUI

/// Measures the chosen microphone's level for the test meter. Uses its own
/// audio engine and runs only while the Audio settings are open.
@MainActor
final class MicLevelMeter: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    private var engine: AVAudioEngine?

    func start() {
        guard !isRunning, InterviewController.shared.phase != .live else { return }
        let engine = AVAudioEngine()
        if let preferred = AudioDeviceManager.preferredInputDeviceID() {
            _ = AudioDeviceManager.setInputDevice(preferred, on: engine)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            error = "No microphone input is available."
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            let level = Self.rms(buffer)
            DispatchQueue.main.async { self?.level = level }
        }
        do {
            try engine.start()
            self.engine = engine
            isRunning = true
            error = nil
        } catch {
            input.removeTap(onBus: 0)
            self.error = "The microphone could not start: \(error.localizedDescription)"
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        level = 0
    }

    /// Loudness 0...1 from the first channel (about -60 dB to 0 dB).
    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-6))
        return min(max((decibels + 60) / 60, 0), 1)
    }
}

/// Choose and test the microphone; see whether both sides can be recorded.
struct AudioSettingsTab: View {
    @StateObject private var meter = MicLevelMeter()
    @State private var devices = AudioDeviceManager.inputDevices()
    @State private var selection = AudioDeviceManager.preferredInputUID ?? ""
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var callAudioAllowed = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: $selection) {
                    Text("System default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.id) }
                }
                .onChange(of: selection) { _, uid in
                    AudioDeviceManager.preferredInputUID = uid.isEmpty ? nil : uid
                    if meter.isRunning { meter.stop(); meter.start() }
                }
                HStack {
                    Button(meter.isRunning ? "Stop Test" : "Test Microphone") {
                        meter.isRunning ? meter.stop() : meter.start()
                    }
                    .disabled(micStatus != .authorized)
                    ProgressView(value: Double(meter.level))
                        .tint(meter.level > 0.85 ? .red : .green)
                        .opacity(meter.isRunning ? 1 : 0.3)
                }
                if let error = meter.error { Text(error).foregroundStyle(.red) }
            } header: {
                Text("Your microphone")
            } footer: {
                Text("Speak normally: the bar should move to about the middle. A headset microphone gives the cleanest timing.")
            }

            Section("Before an interview") {
                if micStatus == .notDetermined {
                    LabeledContent("Microphone access") {
                        Button("Allow Microphone\u{2026}") {
                            Task {
                                _ = await AVCaptureDevice.requestAccess(for: .audio)
                                micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                            }
                        }
                    }
                } else {
                    statusRow("Microphone access", ok: micStatus == .authorized,
                              detail: "Turn on \(AppBrand.name) in Privacy & Security \u{203A} Microphone",
                              settings: "Privacy_Microphone")
                }
                statusRow("Call audio (Screen & System Audio Recording)", ok: callAudioAllowed,
                          detail: callAudioAllowed ? nil : "Needed to hear the candidate; reopen the app after allowing",
                          settings: "Privacy_ScreenCapture")
                statusRow("Deepgram key", ok: VoiceSignatureStore.shared.hasDeepgramApiKey,
                          detail: "Settings \u{203A} Keys", settings: nil)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            devices = AudioDeviceManager.inputDevices()
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            callAudioAllowed = CGPreflightScreenCaptureAccess()
        }
        .onDisappear { meter.stop() }
    }

    private func statusRow(_ title: String, ok: Bool, detail: String?, settings pane: String?) -> some View {
        LabeledContent {
            HStack {
                if !ok, let pane {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                    }
                }
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(ok ? .green : .orange)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !ok, let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
