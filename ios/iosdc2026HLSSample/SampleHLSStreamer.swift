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

final class SampleHLSStreamer {
    private let recorder: HLSSegmentRecorder
    private let fragmentSeconds: Double
    private let targetDurationSec: Int

    private var uploadCoordinator: HLSUploadCoordinator?
    private var uploadChannel: HLSUploadEventChannel?
    private var uploadTask: Task<Void, Never>?
    private var lastSnapshot: HLSUploadSnapshot?

    var captureSession: AVCaptureSession {
        recorder.captureSession
    }

    var recordedSeconds: Double {
        recorder.recordedSeconds
    }

    init(
        fragmentSeconds: Double = 2.0,
        targetDurationSec: Int = 2,
        recorder: HLSSegmentRecorder? = nil
    ) {
        self.fragmentSeconds = fragmentSeconds
        self.targetDurationSec = targetDurationSec
        self.recorder = recorder ?? HLSSegmentRecorder(config: .init(segmentSeconds: fragmentSeconds))
    }

    func startPreview() async throws {
        if !recorder.isRunning {
            try await recorder.start()
        }
    }

    func checkServer(baseURL: URL) async throws {
        let client = try HTTPHLSClient(baseURL: baseURL)
        try await client.healthCheck()
    }

    func startRecording(serverBaseURL: URL) async throws -> HLSUploadSnapshot {
        guard uploadCoordinator == nil else {
            throw SampleHLSStreamError.recordingAlreadyActive
        }

        let client = try HTTPHLSClient(baseURL: serverBaseURL)
        try await client.healthCheck()

        let streamId = Self.makeStreamId()
        let coordinator = HLSUploadCoordinator(
            client: client,
            streamId: streamId,
            targetDurationSec: targetDurationSec
        )
        let channel = HLSUploadEventChannel()

        recorder.onInitSegment = { [channel] data in
            channel.yield(.initialization(data))
        }
        recorder.onMediaSegment = { [channel, fragmentSeconds] seq, data, _ in
            channel.yield(.media(seq: seq, data: data, durationSec: fragmentSeconds))
        }

        uploadCoordinator = coordinator
        uploadChannel = channel
        lastSnapshot = nil
        uploadTask = Task {
            await coordinator.consume(channel.stream, channel: channel)
        }

        do {
            try await recorder.startRecording()
        } catch {
            channel.finish()
            await uploadTask?.value
            resetUploadState()
            throw error
        }

        return await coordinator.snapshot(pendingUploadCount: channel.pendingCount)
    }

    func stopRecording() async throws -> HLSUploadSnapshot {
        guard let coordinator = uploadCoordinator,
              let channel = uploadChannel,
              let uploadTask else {
            throw SampleHLSStreamError.noActiveStream
        }

        await recorder.stop()
        channel.finish()
        await uploadTask.value

        let snapshot = await coordinator.snapshot(pendingUploadCount: channel.pendingCount)
        lastSnapshot = snapshot
        resetUploadState()
        return snapshot
    }

    func currentSnapshot() async -> HLSUploadSnapshot? {
        guard let coordinator = uploadCoordinator,
              let channel = uploadChannel else {
            return lastSnapshot
        }
        return await coordinator.snapshot(pendingUploadCount: channel.pendingCount)
    }

    private func resetUploadState() {
        recorder.onInitSegment = nil
        recorder.onMediaSegment = nil
        uploadCoordinator = nil
        uploadChannel = nil
        uploadTask = nil
    }

    private static func makeStreamId() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "stream-\(formatter.string(from: .now))-\(UUID().uuidString.prefix(8))"
    }
}
