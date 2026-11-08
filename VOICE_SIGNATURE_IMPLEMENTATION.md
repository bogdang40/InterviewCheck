# Technical Design: Real-Time “Voice Signature” (Target Speaker ID) with Picovoice Eagle

## Status

Draft (implementation-ready).

## Audience

Engineers implementing the feature in this repo (`memanager/` macOS Swift app).

## Executive Summary

We will add **target speaker identification** (ME vs NOT ME) to real-time transcription by:

1) **Enrolling** the user once to produce a persistent **speaker profile** (voice signature) using Picovoice **Eagle**.
2) Running Eagle in real time on the same audio stream(s) we transcribe, producing a continuous **similarity score**.
3) Assigning each transcribed segment a `SpeakerLabel` (`me`, `other`, `unknown`) based on score + smoothing + thresholds.

This gives robust, device-agnostic identification because Eagle is **text-independent** and designed for streaming inference. It also keeps voice processing **on-device** (audio never leaves the machine), though **AccessKey validation requires internet** at initialization.

Primary reference docs:
- Eagle overview: https://picovoice.ai/docs/eagle/
- Eagle C API: https://picovoice.ai/docs/api/eagle-c/
- Eagle repo README (C usage, includes `pv_eagle_profiler_export_size`): https://github.com/Picovoice/eagle

## Current Codebase Reality (Important Context)

Today, the app labels transcript by **capture source**, not by voice identity:
- Microphone transcription is always labeled `.me`.
- Optional system-audio transcription is always labeled `.other`.

Relevant files:
- `memanager/memanager/Services/AudioCaptureService.swift` (mic + system audio capture, Speech framework transcription)
- `memanager/memanager/Models/TranscriptEntry.swift` (`speaker: me|other`)
- `memanager/memanager/Views/ContextSidebar.swift` (renders transcript bubbles)
- `memanager/memanager/Utilities/SettingsManager.swift` (app settings)
- `memanager/memanager/Utilities/KeychainManager.swift` (secure string storage)

This feature requires decoupling:
- **AudioSource** (where audio came from) vs
- **SpeakerLabel** (who spoke).

## Goals / Non-Goals

### Goals

- Real-time labeling of transcription as:
  - `ME` (high confidence it’s the enrolled user)
  - `OTHER` (someone else)
  - `UNKNOWN` (low confidence; avoid false “ME”)
- Works regardless of capture method:
  - mic that includes multiple voices
  - system audio
  - “single stream” capture where separation is not possible
- Low latency: label changes within ~0.5–1.5s.
- Bias toward **low false-accept** (don’t accidentally label someone else as ME).
- Fully on-device voice processing; store only the profile (no raw audio by default).

### Non-Goals (for v1)

- Full multi-speaker diarization (“Speaker A/B/C”).
- Anti-spoof / liveness detection.
- Cross-user identification across accounts/devices (we only enroll the local user).

## Eagle Capabilities We Rely On (What We Must Implement Around)

### Enrollment (Profiler)

We feed PCM audio to the profiler repeatedly until enrollment reaches 100%. The profiler returns:
- `percentage` (0..100)
- a feedback code if audio is unusable (too short, too noisy, no voice, etc.)

API requirements (C):
- Enrollment audio must be **single-channel, 16-bit PCM** at `pv_sample_rate()`.
- Minimum length per call is obtained via `pv_eagle_profiler_enroll_min_audio_length_samples()`.

### Recognition (Engine)

We feed consecutive fixed-size frames to Eagle:
- frame size in samples is `pv_eagle_frame_length()`
- sample rate must match `pv_sample_rate()`
- output is similarity `scores` in `[0,1]` (higher = more likely it’s the enrolled speaker)

## Proposed Architecture

### Key Concepts (New Types)

**AudioSource** (existing capture routing):
- `.microphone`
- `.systemAudio`

**SpeakerLabel** (new identity classification):
- `.me`
- `.other`
- `.unknown` (default when not confident)

**VoiceSignatureState**
- `enabled: Bool`
- `hasProfile: Bool`
- `thresholdEnterMe: Float`
- `thresholdExitMe: Float` (hysteresis)

**SpeakerScoreSample**
- `t: TimeInterval` (monotonic relative to stream start)
- `score: Float` (0..1)
- `source: AudioSource`

### Components (New Services)

1) `EagleBindings` (thin Swift wrapper over C)
   - Owns `pv_eagle_profiler_t*` and `pv_eagle_t*`
   - Converts error status to Swift errors (use `pv_status_to_string`, `pv_get_error_stack`)

2) `VoiceSignatureStore`
   - Stores `AccessKey` (Keychain)
   - Stores `SpeakerProfile` bytes (Keychain `Data` or encrypted file in Application Support)
   - Stores thresholds & enablement (UserDefaults via `SettingsManager`)

3) `VoiceSignatureEnrollmentService`
   - Takes streaming audio frames (PCM16 @ Eagle SR) and drives:
     - `enroll(minEnrollSamples)` loops
     - progress + feedback surface to UI
   - Outputs `SpeakerProfile` bytes when complete

4) `VoiceSignatureRecognitionService`
   - Loads `SpeakerProfile`, builds `pv_eagle_t*`
   - Consumes a continuous stream of PCM16 frames sized to `pv_eagle_frame_length()`
   - Emits `SpeakerScoreSample` events
   - Applies smoothing + hysteresis to produce stable `SpeakerLabel` state

5) `PCM16ResamplerAndFramer`
   - Converts `AVAudioPCMBuffer` (float or int, any SR, any channels) into:
     - mono PCM16 @ `pv_sample_rate()`
   - Buffers samples and yields exact frames of length `pv_eagle_frame_length()`
   - Runs off the realtime audio callback thread

6) `TranscriptionLabeler`
   - Assigns `SpeakerLabel` to transcript updates
   - Strategy:
     - For **partial** transcription updates: label using “current speaker state”
     - For **final** transcript commits: re-label using timestamps (see next section)

### Data Flow (Runtime)

For each enabled audio source:

`AudioCaptureService` -> `AVAudioPCMBuffer` -> (async queue) -> `PCM16ResamplerAndFramer`
  - outputs Eagle frames -> `VoiceSignatureRecognitionService.process(frame)` -> score samples + speaker state
  - simultaneously feeds the original buffer to `SFSpeechAudioBufferRecognitionRequest.append(buffer)`

`SFSpeechRecognizer` -> partial/final transcription -> `TranscriptionLabeler` -> `TranscriptEntry[]` -> UI

### Timestamp Alignment Strategy (Real-Time + Correctness)

Speech framework gives word/utterance segments with timestamps/durations, but they’re reliable primarily on final results.

Plan:
- Maintain a per-source `scoreTimeline` ring buffer of `(t, score)` samples.
  - `t` computed from a shared `streamStartTime` using monotonic clock (`DispatchTime.now()` deltas).
- On final transcription results, iterate newly-finalized `SFTranscriptionSegment`s:
  - `segmentStart = segment.timestamp`
  - `segmentEnd = segment.timestamp + segment.duration`
  - `segmentScore = avg(scoreTimeline samples overlapping [segmentStart, segmentEnd])`
  - label = `me` iff `segmentScore >= thresholdEnterMe` (or more nuanced: apply state machine)
- On partial results, show speaker label based on current `speakerState` and “recent average score”.

## UI / UX Plan (Settings + Enrollment + Diagnostics)

Add a new Settings tab: **Voice Signature**

### Controls

- Toggle: Enable Voice Signature labeling
- AccessKey field (stored in Keychain)
- Buttons:
  - Enroll / Re-enroll (opens enrollment flow)
  - Delete voice signature (removes stored profile)
- Threshold slider:
  - “Strict” (higher threshold; fewer false ME) -> “Permissive”
  - Internally sets `thresholdEnterMe` and `thresholdExitMe`
- Live test:
  - Shows current ME score and current label while you speak (no transcript needed)

### Enrollment Flow

Enrollment is a guided wizard:
- Requirements displayed:
  - quiet environment, single speaker, normal speaking voice
- Start enrollment: begin capturing audio frames, call `pv_eagle_profiler_enroll` repeatedly until 100%
- Surface feedback (from Eagle feedback enum) as actionable text:
  - audio too short -> “keep speaking”
  - no voice found -> “speak louder”
  - quality issue -> “reduce background noise”
  - unknown speaker -> “only you should be speaking”
- Completion: export profile bytes, store, enable recognition

## Storage / Security / Privacy

Voice signatures are biometric identifiers. Treat them as sensitive.

### Store

- AccessKey: Keychain (already exists for AI keys)
- Eagle profile bytes:
  - Preferred: Keychain as `Data` (extend KeychainManager)
  - Alternative: encrypted file in `Application Support`, key stored in Keychain

### Never store by default

- Raw audio used during enrollment (unless user explicitly opts in for diagnostics)

### Delete

- Provide “Delete voice signature” to remove stored profile and reset engine.

## Build/Integration Plan (Picovoice Eagle on macOS)

This app is macOS (XcodeGen, no CocoaPods). Picovoice’s iOS packages are not the right fit; use the **C SDK** on macOS.

### Inputs from Picovoice

From Eagle distribution (release or cloned repo):
- `include/pv_eagle.h` (and any required common headers, e.g., `picovoice.h`)
- macOS dynamic library for arm64/x86_64 (likely `.dylib`)
- default model file (`.pv`) under `lib/common/` per Picovoice docs

### Proposed repo layout

Create (example):

```
memanager/third_party/picovoice/eagle/
  include/
  lib/macos/arm64/
  lib/macos/x86_64/
  model/eagle_params.pv (actual name from SDK)
```

### Xcode project wiring (XcodeGen)

Update `memanager/project.yml` to:
- Add header search paths (`HEADER_SEARCH_PATHS`)
- Add library search paths (`LIBRARY_SEARCH_PATHS`)
- Link the Eagle dylib (`OTHER_LDFLAGS` or “Link Binary With Libraries”)
- Copy the dylib into the app bundle at build time
- Ensure the dylib is code-signed with the app (hardened runtime)
- Add the `.pv` model file as a bundled resource

### Swift ↔ C bridging options

Preferred: create a Clang module with a `module.modulemap` so Swift can `import EagleC`.
Alternative: bridging header (less clean in multi-target setups).

## Implementation Details (Engineering Notes)

### Audio Conversion (Critical)

Eagle requires:
- sample rate: `pv_sample_rate()` (query at runtime)
- mono
- 16-bit PCM
- frames of exactly `pv_eagle_frame_length()` samples

Our app currently captures:
- mic: `AVAudioEngine` input node format (often float, variable SR/channels)
- system audio: configured 48kHz mono; sample buffers may be float/interleaved

Plan:
- Use `AVAudioConverter` to convert *any incoming buffer* to:
  - `AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: eagleSampleRate, channels: 1, interleaved: true)`
- Feed converted PCM16 samples into a framer that yields fixed-sized frames.
- Do conversion + framing on a serial queue per source to keep ordering.

### Real-time Threading

Do not run heavy conversion on the audio I/O thread.

Recommended approach:
- In the audio tap callback, quickly enqueue/copy the buffer to a processing queue.
- The processing queue performs:
  - convert -> append samples to ring buffer -> emit frames -> Eagle process

### Speaker State Machine (Stability + Safety)

We want stability and low false ME.

Inputs:
- `score` ∈ [0,1] per frame

State:
- `currentLabel`: me|other|unknown
- `smoothedScore`: EMA(score)
- hysteresis thresholds:
  - enter ME at `T_enter` (e.g., 0.85)
  - exit ME at `T_exit` (e.g., 0.75)
- minimum duration gating:
  - require `N` consecutive frames above `T_enter` to enter ME
  - require `M` consecutive frames below `T_exit` to exit ME

Output:
- `speakerState` used for partial transcript labeling

### Transcript Entry Model Changes

Update `TranscriptEntry` (or create `VoiceLabeledTranscriptEntry`) to include:
- `source: AudioSource`
- `label: SpeakerLabel`
- `confidence: Float` (derived from segmentScore)
- optionally `timeRange` for debugging/diagnostics

Keep UI behavior:
- keep transcript readable (merge adjacent bubbles with same label + source)
- show UNKNOWN distinctly (e.g., gray)

## Error Handling / Fallbacks

### Eagle init failures

Eagle functions can fail with status codes:
- invalid access key / activation throttling / refused
- IO errors loading model

Plan:
- Surface a non-blocking warning (Settings tab + transcript header indicator).
- Fall back to current behavior (source-based labeling) when voice signature is unavailable.

### Offline behavior

Even though inference is offline, AccessKey validation requires internet at least on initialization. Ensure UX explains this clearly.

## Testing & Validation Plan

### Manual tests (must-have)

1) Enrollment happy path:
   - quiet room; enroll reaches 100%; profile persists across app restart
2) Enrollment failure feedback:
   - play music / silence / another person; ensure feedback changes appropriately
3) Recognition:
   - while speaking: score high and label becomes ME within ~1s
   - while another person speaks into mic: score stays low; label OTHER/UNKNOWN
4) Mixed audio:
   - Zoom call where mic picks up both you + speaker audio
   - verify transcription segments are labeled correctly
5) Fallback:
   - delete profile; verify system returns to source-based labeling

### Quantitative calibration (recommended)

Build an internal “calibration” mode:
- Record ~60s of you speaking (varied)
- Record ~60s of someone else speaking (or a podcast)
- Compute score distributions and suggest `T_enter/T_exit` defaults.

## Work Breakdown (Delegation Checklist)

### A) Model + Build Integration

- [ ] Add Picovoice Eagle C SDK + model file to repo (or documented download step)
- [ ] Update XcodeGen config to link, embed, sign the dylib
- [ ] Add module map / Swift import mechanism

### B) Storage + Settings

- [ ] Extend KeychainManager to store/load `Data` blobs (profile bytes)
- [ ] Add SettingsManager keys for:
  - voiceSignatureEnabled
  - voiceSignatureThresholds
  - picovoiceAccessKey
- [ ] Add Settings UI tab for Voice Signature

### C) Eagle Wrapper + Services

- [ ] Implement `EagleBindings` wrapper (profiler + engine)
- [ ] Implement `VoiceSignatureEnrollmentService`
- [ ] Implement `VoiceSignatureRecognitionService` + smoothing/hysteresis
- [ ] Implement `PCM16ResamplerAndFramer`

### D) Wire into AudioCaptureService

- [ ] Add per-source processing queues and frame pipelines
- [ ] Feed audio to Eagle alongside Speech recognition
- [ ] Produce speaker state + score timeline

### E) Transcript labeling & UI

- [ ] Update transcript model: source vs label
- [ ] Implement `TranscriptionLabeler` (partial vs final alignment)
- [ ] Update UI bubbles + transcript views

### F) Diagnostics

- [ ] Add live “Test” view for score
- [ ] Add debug logging (behind `#if DEBUG`) for:
  - current score, state transitions, enrollment feedback

## Acceptance Criteria (Definition of Done)

- Enrollment reaches 100% and persists across restarts.
- In a mixed-speaker microphone stream, the app reliably labels the user’s speech as ME and others as OTHER/UNKNOWN.
- False “ME” on other speakers is rare (target: <1 per hour of mixed audio in typical conditions).
- CPU impact is acceptable for a background macOS agent (no UI lag; audio dropouts not observed).
- Feature can be disabled and fully deleted.

