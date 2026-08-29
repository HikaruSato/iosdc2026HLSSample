@preconcurrency import AVFoundation
import Foundation

// CaptureSession state and Writer state are confined to their dedicated serial queues.
final class HLSSegmentRecorder: NSObject, @unchecked Sendable {
    struct Config: Sendable {
        var videoSize = CGSize(width: 720, height: 1280)
        var videoBitrate = 1_500_000
        var audioBitrate = 64_000
        var segmentSeconds = 2.0
    }

    private let config: Config
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "sample.capture.session.queue")
    private let writingQueue = DispatchQueue(label: "sample.hls.writer.queue")

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    // writingQueue only
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var fragmentContinuation: AsyncThrowingStream<HLSFragment, Error>.Continuation?
    private var isWriting = false
    private var didStartSession = false
    private var timeOffsetDelta: CMTime?
    private var lastAdjustedPTS: CMTime = .invalid
    private var segmentIndex = 0

    private let startTimeOffset = CMTime(value: 10, timescale: 1)

    var captureSession: AVCaptureSession {
        session
    }

    init(config: Config) {
        self.config = config
        super.init()
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    guard !self.session.isRunning else {
                        continuation.resume()
                        return
                    }

                    try self.configureAudioSession()
                    try self.setupCaptureSessionLocked()
                    self.session.startRunning()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func startRecording() async throws -> AsyncThrowingStream<HLSFragment, Error> {
        let fragments = AsyncThrowingStream<HLSFragment, Error>.makeStream()

        try await withCheckedThrowingContinuation { continuation in
            writingQueue.async {
                do {
                    guard self.fragmentContinuation == nil else {
                        throw HLSSegmentRecorderError.recordingAlreadyActive
                    }

                    try self.setupWriterLocked()
                    self.fragmentContinuation = fragments.continuation
                    self.isWriting = true
                    continuation.resume()
                } catch {
                    fragments.continuation.finish(throwing: error)
                    continuation.resume(throwing: error)
                }
            }
        }

        return fragments.stream
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                continuation.resume()
            }
        }

        await withCheckedContinuation { continuation in
            writingQueue.async {
                self.isWriting = false
                self.finishWriterLocked { error in
                    self.finishFragmentStreamLocked(throwing: error)
                    self.cleanupWriterLocked()
                    continuation.resume()
                }
            }
        }
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
        try audioSession.setActive(true)
    }

    private func setupCaptureSessionLocked() throws {
        if !session.inputs.isEmpty || !session.outputs.isEmpty { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high

        guard let videoDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else {
            throw HLSSegmentRecorderError.cameraUnavailable
        }
        session.addInput(videoInput)

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: writingQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        audioOutput.setSampleBufferDelegate(self, queue: writingQueue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        }

        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    private func setupWriterLocked() throws {
        cleanupWriterLocked()

        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(
            seconds: config.segmentSeconds,
            preferredTimescale: 600
        )
        writer.initialSegmentStartTime = startTimeOffset
        writer.delegate = self

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings())
        videoInput.expectsMediaDataInRealTime = true

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings())
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw HLSSegmentRecorderError.cannotAddWriterInputs
        }

        writer.add(videoInput)
        writer.add(audioInput)

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        didStartSession = false
        timeOffsetDelta = nil
        lastAdjustedPTS = .invalid
        segmentIndex = 0
    }

    private func videoSettings() -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.videoSize.width,
            AVVideoHeightKey: config.videoSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: config.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: config.segmentSeconds,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
    }

    private func audioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: config.audioBitrate
        ]
    }

    private func finishWriterLocked(completion: @escaping @Sendable (Error?) -> Void) {
        guard let writer else {
            completion(nil)
            return
        }

        switch writer.status {
        case .writing:
            if lastAdjustedPTS.isValid {
                writer.endSession(atSourceTime: lastAdjustedPTS)
            }

            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            writer.finishWriting { [self] in
                writingQueue.async { [self] in
                    let error = self.writer?.status == .completed
                        ? nil
                        : HLSSegmentRecorderError.writerFailed(
                            action: "finishWriting",
                            reason: self.writer?.error?.localizedDescription
                        )
                    completion(error)
                }
            }

        case .failed, .cancelled:
            completion(HLSSegmentRecorderError.writerFailed(
                action: "finishWriting",
                reason: writer.error?.localizedDescription
            ))

        case .unknown, .completed:
            completion(nil)

        @unknown default:
            completion(HLSSegmentRecorderError.writerFailed(
                action: "finishWriting",
                reason: writer.error?.localizedDescription
            ))
        }
    }

    private func failWriterLocked(action: String) {
        let error = HLSSegmentRecorderError.writerFailed(
            action: action,
            reason: writer?.error?.localizedDescription
        )
        if writer?.status == .writing {
            writer?.cancelWriting()
        }
        isWriting = false
        finishFragmentStreamLocked(throwing: error)
        cleanupWriterLocked()
    }

    private func finishFragmentStreamLocked(throwing error: Error?) {
        if let error {
            fragmentContinuation?.finish(throwing: error)
        } else {
            fragmentContinuation?.finish()
        }
        fragmentContinuation = nil
    }

    private func cleanupWriterLocked() {
        writer = nil
        videoInput = nil
        audioInput = nil
        didStartSession = false
        timeOffsetDelta = nil
        lastAdjustedPTS = .invalid
    }
}

extension HLSSegmentRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isWriting, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        startWriterIfNeeded(output: output, sampleBuffer: sampleBuffer)
        append(output: output, sampleBuffer: sampleBuffer)
    }

    private func startWriterIfNeeded(output: AVCaptureOutput, sampleBuffer: CMSampleBuffer) {
        guard output === videoOutput else { return }
        guard !didStartSession, let writer else { return }

        guard writer.startWriting() else {
            failWriterLocked(action: "startWriting")
            return
        }

        didStartSession = true
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.startSession(atSourceTime: startTimeOffset)
        timeOffsetDelta = startTimeOffset - pts
    }

    private func append(output: AVCaptureOutput, sampleBuffer: CMSampleBuffer) {
        guard didStartSession,
              let videoInput,
              let audioInput,
              let timeOffsetDelta else { return }

        let adjustedSampleBuffer: CMSampleBuffer
        do {
            adjustedSampleBuffer = try sampleBuffer.offsettingTiming(by: timeOffsetDelta)
        } catch {
            failWriterLocked(action: "adjust sample timing")
            return
        }

        let adjustedPTS = CMSampleBufferGetPresentationTimeStamp(adjustedSampleBuffer)
        if !lastAdjustedPTS.isValid || adjustedPTS > lastAdjustedPTS {
            lastAdjustedPTS = adjustedPTS
        }

        let didAppend: Bool
        if output === videoOutput {
            guard videoInput.isReadyForMoreMediaData else { return }
            didAppend = videoInput.append(adjustedSampleBuffer)
        } else {
            guard audioInput.isReadyForMoreMediaData else { return }
            didAppend = audioInput.append(adjustedSampleBuffer)
        }

        if !didAppend {
            failWriterLocked(action: "append")
        }
    }
}

extension HLSSegmentRecorder: AVAssetWriterDelegate {
    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        let duration = segmentDuration(from: segmentReport)

        writingQueue.async {
            guard let continuation = self.fragmentContinuation else { return }

            switch segmentType {
            case .initialization:
                continuation.yield(.initialization(segmentData))

            case .separable:
                self.segmentIndex += 1
                continuation.yield(.media(
                    sequence: self.segmentIndex,
                    data: segmentData,
                    duration: duration
                ))

            @unknown default:
                break
            }
        }
    }

    private func segmentDuration(from report: AVAssetSegmentReport?) -> Double {
        guard let track = report?.trackReports.first(where: { $0.mediaType == .video }) else {
            return config.segmentSeconds
        }

        let duration = track.duration.seconds
        return duration.isFinite && duration > 0 ? duration : config.segmentSeconds
    }
}

enum HLSSegmentRecorderError: LocalizedError {
    case recordingAlreadyActive
    case cameraUnavailable
    case cannotAddWriterInputs
    case writerFailed(action: String, reason: String?)

    var errorDescription: String? {
        switch self {
        case .recordingAlreadyActive:
            return "すでに録画中です"
        case .cameraUnavailable:
            return "カメラをCaptureSessionへ追加できませんでした"
        case .cannotAddWriterInputs:
            return "映像または音声をAVAssetWriterへ追加できませんでした"
        case let .writerFailed(action, reason):
            return ["AVAssetWriterの\(action)に失敗しました", reason]
                .compactMap { $0 }
                .joined(separator: ": ")
        }
    }
}

private extension CMSampleBuffer {
    func offsettingTiming(by offset: CMTime) throws -> CMSampleBuffer {
        let timingInfos: [CMSampleTimingInfo]
        do {
            timingInfos = try sampleTimingInfos().map { info in
                var adjusted = info
                adjusted.presentationTimeStamp = info.presentationTimeStamp + offset
                if info.decodeTimeStamp.isValid {
                    adjusted.decodeTimeStamp = info.decodeTimeStamp + offset
                }
                return adjusted
            }
        } catch {
            timingInfos = []
        }

        let copied = try CMSampleBuffer(copying: self, withNewTiming: timingInfos)
        try copied.setOutputPresentationTimeStamp(copied.outputPresentationTimeStamp + offset)
        return copied
    }
}
