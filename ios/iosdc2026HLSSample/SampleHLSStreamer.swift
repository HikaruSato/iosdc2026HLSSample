import AVFoundation
import Foundation

enum SampleHLSStreamError: LocalizedError {
    case recordingAlreadyActive
    case noActiveStream

    var errorDescription: String? {
        switch self {
        case .recordingAlreadyActive:
            return "すでに録画中です"
        case .noActiveStream:
            return "録画中のstreamがありません"
        }
    }
}

@MainActor
final class SampleHLSStreamer {
    private struct ActiveStream {
        let publisher: HLSStreamPublisher
        let uploadTask: Task<Void, Never>
    }

    private let recorder: HLSSegmentRecorder
    private let targetDurationSec: Int

    private var activeStream: ActiveStream?
    private var lastSnapshot: HLSStreamSnapshot?
    private var isPreviewRunning = false
    private var recordingStartedAt: Date?

    var captureSession: AVCaptureSession {
        recorder.captureSession
    }

    var recordedSeconds: Double {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    init(
        fragmentSeconds: Double = 2.0,
        targetDurationSec: Int = 2,
        recorder: HLSSegmentRecorder? = nil
    ) {
        self.targetDurationSec = targetDurationSec
        self.recorder = recorder ?? HLSSegmentRecorder(config: .init(segmentSeconds: fragmentSeconds))
    }

    func startPreview() async throws {
        guard !isPreviewRunning else { return }
        try await recorder.start()
        isPreviewRunning = true
    }

    func checkServer(baseURL: URL) async throws {
        let client = try HTTPHLSClient(baseURL: baseURL)
        try await client.healthCheck()
    }

    func startRecording(serverBaseURL: URL) async throws -> HLSStreamSnapshot {
        guard activeStream == nil else {
            throw SampleHLSStreamError.recordingAlreadyActive
        }

        let client = try HTTPHLSClient(baseURL: serverBaseURL)
        try await client.healthCheck()

        let publisher = HLSStreamPublisher(
            client: client,
            streamId: Self.makeStreamId(),
            targetDurationSec: targetDurationSec
        )
        let fragments = try await recorder.startRecording()
        let uploadTask = Task {
            await publisher.publish(fragments)
        }

        activeStream = ActiveStream(publisher: publisher, uploadTask: uploadTask)
        lastSnapshot = nil
        recordingStartedAt = .now
        return await publisher.snapshot()
    }

    func stopRecording() async throws -> HLSStreamSnapshot {
        guard let activeStream else {
            throw SampleHLSStreamError.noActiveStream
        }

        await recorder.stop()
        await activeStream.uploadTask.value

        let snapshot = await activeStream.publisher.snapshot()
        lastSnapshot = snapshot
        self.activeStream = nil
        recordingStartedAt = nil
        isPreviewRunning = false
        return snapshot
    }

    func currentSnapshot() async -> HLSStreamSnapshot? {
        guard let activeStream else { return lastSnapshot }
        return await activeStream.publisher.snapshot()
    }

    private static func makeStreamId() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "stream-\(formatter.string(from: .now))-\(UUID().uuidString.prefix(8))"
    }
}
