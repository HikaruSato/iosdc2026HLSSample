@preconcurrency import AVFoundation
import VideoToolbox

struct LocalRecordingError: LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}

typealias LocalRecordingResult = Result<URL, LocalRecordingError>

/// RecorderのwritingQueueだけから操作する、保存用の独立したWriter。
final class LocalVideoWriter: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput.SampleBufferReceiver
    private let audio: AVAssetWriterInput.SampleBufferReceiver
    private let workingURL: URL
    private var started = false
    private var videoCount = 0
    private var audioCount = 0
    private var failure: LocalRecordingError?

    init(directory: URL? = nil) throws {
        let directory = try directory ?? LocalRecordingFiles.directory()
        workingURL = directory.appendingPathComponent(UUID().uuidString + ".recording.mp4")
        writer = try AVAssetWriter(outputURL: workingURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 1080,
            AVVideoHeightKey: 1920,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 5_000_000,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 96_000
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video),
              writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
            throw LocalRecordingError(message: "フルHD・HEVCの保存設定を利用できません")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        videoInput.expectsMediaDataInRealTime = true
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw LocalRecordingError(message: "保存用Writerへ映像・音声を追加できません")
        }
        video = writer.inputReceiver(for: videoInput)
        audio = writer.inputReceiver(for: audioInput)
    }

    func append(_ sampleBuffer: CMSampleBuffer, isVideo: Bool) {
        guard failure == nil else { return }
        do {
            if !started {
                guard isVideo else { return }
                guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer),
                      CVPixelBufferGetWidth(pixel) == 1080,
                      CVPixelBufferGetHeight(pixel) == 1920 else {
                    throw LocalRecordingError(message: "撮影データが縦向きフルHDではありません")
                }
                try writer.start()
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                started = true
            }
            // HLS側の時刻補正・所有権移譲から独立したコピーを渡す。
            nonisolated(unsafe) let copy = try CMSampleBuffer(copying: sampleBuffer)
            let ready = CMReadySampleBuffer(unsafeBuffer: copy)
            let accepted = try (isVideo ? video : audio).appendImmediately(ready)
            if accepted {
                if isVideo { videoCount += 1 } else { audioCount += 1 }
            }
        } catch {
            failure = LocalRecordingError(message: "保存用Writer: \(error.localizedDescription)")
            writer.cancelWriting()
        }
    }

    func cancel() {
        if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: workingURL)
    }

    func finish(on queue: DispatchQueue, completion: @escaping @Sendable (LocalRecordingResult) -> Void) {
        guard failure == nil, started, videoCount > 0, audioCount > 0,
              writer.status == .writing else {
            let error = failure ?? LocalRecordingError(message: "映像・音声の揃った保存動画を生成できませんでした")
            cancel()
            completion(.failure(error))
            return
        }
        video.finish()
        audio.finish()
        writer.finishWriting { [self] in
            queue.async { [self] in
                guard writer.status == .completed else {
                    let error = LocalRecordingError(message: writer.error?.localizedDescription ?? "MP4の完成に失敗しました")
                    cancel()
                    completion(.failure(error))
                    return
                }
                do {
                    // completedのファイルだけが写真保存の再試行対象になる。
                    let completedURL = workingURL.deletingLastPathComponent()
                        .appendingPathComponent(workingURL.lastPathComponent.replacingOccurrences(of: ".recording.mp4", with: ".mp4"))
                    try FileManager.default.moveItem(at: workingURL, to: completedURL)
                    completion(.success(completedURL))
                } catch {
                    completion(.failure(LocalRecordingError(message: error.localizedDescription)))
                }
            }
        }
    }
}

enum LocalRecordingFiles {
    static func directory() throws -> URL {
        let url = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("LocalRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func pending() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mp4" && !$0.lastPathComponent.hasSuffix(".recording.mp4") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
