import AVFoundation
import Foundation

final class LocalHLSStreamer {
    private let recorder: HLSSegmentRecorder
    private let store: LocalHLSStreamStore
    private let fragmentSeconds: Double
    private let targetDurationSec: Int
    private var activeStream: LocalHLSStream?

    var captureSession: AVCaptureSession {
        recorder.captureSession
    }

    var recordedSeconds: Double {
        recorder.recordedSeconds
    }

    init(
        fragmentSeconds: Double = 2.0,
        targetDurationSec: Int = 2,
        recorder: HLSSegmentRecorder? = nil,
        store: LocalHLSStreamStore = LocalHLSStreamStore()
    ) {
        self.fragmentSeconds = fragmentSeconds
        self.targetDurationSec = targetDurationSec
        self.recorder = recorder ?? HLSSegmentRecorder(config: .init(segmentSeconds: fragmentSeconds))
        self.store = store
    }

    func startPreview() async throws {
        if !recorder.isRunning {
            try await recorder.start()
        }
    }

    func startRecording() async throws -> LocalHLSStreamSnapshot {
        let stream = try await store.createStream(targetDurationSec: targetDurationSec)
        activeStream = stream

        recorder.onInitSegment = { [store] data in
            Task {
                try? await store.saveInitSegment(data, for: stream)
            }
        }

        recorder.onMediaSegment = { [store, fragmentSeconds] seq, data, _ in
            Task {
                try? await store.saveMediaSegment(
                    seq: seq,
                    data: data,
                    durationSec: fragmentSeconds,
                    for: stream
                )
            }
        }

        try await recorder.startRecording()
        return try await store.snapshot(for: stream)
    }

    func stopRecording() async throws -> LocalHLSStreamSnapshot {
        guard let activeStream else {
            throw LocalHLSStreamError.noActiveStream
        }

        await recorder.stop()
        try await store.finish(stream: activeStream)
        let snapshot = try await store.snapshot(for: activeStream)
        self.activeStream = nil
        return snapshot
    }

    func currentSnapshot() async throws -> LocalHLSStreamSnapshot? {
        guard let activeStream else { return nil }
        return try await store.snapshot(for: activeStream)
    }
}
