import AVFoundation
import Foundation

/// 配信の開始・停止というFacadeの操作に失敗した理由。
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

/// 画面からHLS配信を操作するためのFacade。
///
/// この型自身は映像を加工せず、次の2つを接続する。
///
/// - ``HLSSegmentRecorder``: カメラとマイクからHLS fragmentを生成する
/// - ``HLSStreamPublisher``: fragmentを再生可能な順番でHTTP公開する
///
/// UIから安全に状態を参照できるよう、配信中の状態と経過時間はMainActor上で管理する。
@MainActor
final class SampleHLSStreamer {
    /// Publisherと、その入力streamを消費するTaskは同じ寿命を持つため、1つの状態にまとめる。
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

    /// SwiftUIのカメラプレビューへ渡すCaptureSession。
    var captureSession: AVCaptureSession {
        recorder.captureSession
    }

    /// UI表示用の経過時間。メディアのPTSとは別に、MainActor上の壁時計で計測する。
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

    /// カメラとマイクを準備し、プレビュー用のCaptureSessionを開始する。
    /// Writerはまだ開始しないため、この時点ではHLS fragmentは生成されない。
    func startPreview() async throws {
        guard !isPreviewRunning else { return }
        try await recorder.start()
        isPreviewRunning = true
    }

    /// 配信開始前にサーバーへ到達できることを確認する。
    func checkServer(baseURL: URL) async throws {
        let client = try HTTPHLSClient(baseURL: baseURL)
        try await client.healthCheck()
    }

    /// Recorderが返すfragment streamをPublisherのconsumer Taskへ接続し、配信を開始する。
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

        // Writerを動かす前にstreamを受け取る。最初のinit.mp4を取りこぼさないための開始順である。
        let fragments = try await recorder.startRecording()
        let uploadTask = Task {
            await publisher.publish(fragments)
        }

        activeStream = ActiveStream(publisher: publisher, uploadTask: uploadTask)
        lastSnapshot = nil
        recordingStartedAt = .now
        return await publisher.snapshot()
    }

    /// 最後のfragmentとENDLIST付きplaylistまで公開してから、配信を終了する。
    func stopRecording() async throws -> HLSStreamSnapshot {
        guard let activeStream else {
            throw SampleHLSStreamError.noActiveStream
        }

        // 1. Captureを止め、Writerをdrainし、fragment streamを閉じる。
        await recorder.stop()
        // 2. Publisherがstream完了を受け取り、ENDLISTをPUTするまで待つ。
        await activeStream.uploadTask.value

        let snapshot = await activeStream.publisher.snapshot()
        lastSnapshot = snapshot
        self.activeStream = nil
        recordingStartedAt = nil
        isPreviewRunning = false
        return snapshot
    }

    /// 配信中は現在値、配信終了後は最後に確定した値を返す。
    func currentSnapshot() async -> HLSStreamSnapshot? {
        guard let activeStream else { return lastSnapshot }
        return await activeStream.publisher.snapshot()
    }

    /// 保存先が衝突せず、一覧でも開始時刻を判別できるstream IDを作る。
    private static func makeStreamId() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "stream-\(formatter.string(from: .now))-\(UUID().uuidString.prefix(8))"
    }
}
