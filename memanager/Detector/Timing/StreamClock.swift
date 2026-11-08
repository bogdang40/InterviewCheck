import Foundation

/// Maps Deepgram stream offsets back to the host clock for one socket
/// connection.
///
/// Deepgram times every word in seconds of audio *received on that socket*.
/// Each chunk handed to the socket is recorded here, in send order, with
/// the host time its audio started. Contiguous chunks form a run; a run
/// breaks when a chunk's start drifts from where the audio clock says it
/// should be by more than `gapTolerance` (audio was dropped, queued while
/// connecting, or delivered late). Offsets inside a run convert exactly;
/// breaks are counted so callers can lower their confidence.
final class StreamClock {
    struct Run: Equatable {
        let offsetStart: TimeInterval
        let hostStart: TimeInterval
        var duration: TimeInterval
    }

    let bytesPerSecond: Double
    let gapTolerance: TimeInterval

    private let lock = NSLock()
    private var runs: [Run] = []
    private var sentDuration: TimeInterval = 0
    private var breaks = 0

    /// Defaults match the router's output: 48 kHz mono PCM16.
    init(
        bytesPerSecond: Double = Double(DeepgramStreamCore.Config.sampleRate * 2 * DeepgramStreamCore.Config.channels),
        gapTolerance: TimeInterval = 0.5
    ) {
        self.bytesPerSecond = bytesPerSecond
        self.gapTolerance = gapTolerance
    }

    /// Seconds of audio a chunk of `byteCount` bytes holds.
    func duration(ofBytes byteCount: Int) -> TimeInterval {
        bytesPerSecond > 0 ? Double(byteCount) / bytesPerSecond : 0
    }

    /// Host time the audio in a chunk started, for a chunk that arrived now.
    func captureStart(ofBytes byteCount: Int, arrivedAt uptime: TimeInterval) -> TimeInterval {
        uptime - duration(ofBytes: byteCount)
    }

    /// Forget everything; call when a new socket connection starts, because
    /// Deepgram's offsets restart at zero for each connection.
    func reset() {
        lock.withLock {
            runs.removeAll()
            sentDuration = 0
            breaks = 0
        }
    }

    /// Record a chunk in the same order it is handed to the socket.
    func recordSent(byteCount: Int, capturedAt hostStart: TimeInterval) {
        let chunkDuration = duration(ofBytes: byteCount)
        guard chunkDuration > 0 else { return }
        lock.withLock {
            if let lastIndex = runs.indices.last {
                let last = runs[lastIndex]
                let expected = last.hostStart + last.duration
                if abs(hostStart - expected) <= gapTolerance {
                    runs[lastIndex].duration += chunkDuration
                    sentDuration += chunkDuration
                    return
                }
                breaks += 1
            }
            runs.append(Run(offsetStart: sentDuration, hostStart: hostStart, duration: chunkDuration))
            sentDuration += chunkDuration
        }
    }

    /// Host time for a Deepgram offset, or nil before any audio was sent.
    func hostTime(forOffset offset: TimeInterval) -> TimeInterval? {
        lock.withLock {
            // Recent offsets sit at the end, so scan backwards.
            guard let run = runs.last(where: { $0.offsetStart <= offset }) ?? runs.first else { return nil }
            return run.hostStart + (offset - run.offsetStart)
        }
    }

    /// Number of times the stream's audio was not contiguous.
    var breakCount: Int { lock.withLock { breaks } }

    var snapshot: [Run] { lock.withLock { runs } }
}
