@preconcurrency import AVFoundation
import Foundation

final class HLSSegmentRecorder: NSObject {
    struct Config {
        var videoSize = CGSize(width: 720, height: 1280)
        var videoBitrate = 1_500_000
        var audioBitrate = 64_000
        var segmentSeconds = 2.0
    }

    private var config: Config
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "sample.capture.session.queue")
    private let writingQueue = DispatchQueue(label: "sample.hls.writer.queue")

    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    private var isWriting = false
    private var isStopping = false
    private var didStartSession = false
    private var recordingStartedAt: Date?

    private let startTimeOffset = CMTime(value: 10, timescale: 1)
    private var firstVideoPTS: CMTime?
    private var timeOffsetDelta: CMTime?
    private var lastAdjustedPTS: CMTime = .invalid
    private var segmentIndex = 0

    var onInitSegment: ((Data) -> Void)?
    var onMediaSegment: ((Int, Data, AVAssetSegmentReport?) -> Void)?

    var captureSession: AVCaptureSession {
        session
    }

    var isRunning: Bool {
        session.isRunning
    }

    var recordedSeconds: Double {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    init(config: Config) {
        self.config = config
        super.init()
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
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

    func startRecording() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    try self.setupWriterLocked()
                    self.isWriting = true
                    self.recordingStartedAt = .now
                    continuation.resume()
                } catch {
                    self.isWriting = false
                    self.recordingStartedAt = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        guard !isStopping else { return }
        isStopping = true

        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.isWriting = false
                self.session.stopRunning()
                continuation.resume()
            }
        }

        await withCheckedContinuation { continuation in
            writingQueue.async {
                self.finishWriterLocked {
                    self.cleanupWriterLocked()
                    self.recordingStartedAt = nil
                    self.isStopping = false
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
        session.sessionPreset = .high

        guard let videoDevice = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              session.canAddInput(videoInput) else {
            throw NSError(domain: "HLSSegmentRecorder.Capture", code: -1)
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

        session.commitConfiguration()
    }

    private func setupWriterLocked() throws {
        cleanupWriterLocked()

        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.shouldOptimizeForNetworkUse = true
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
            throw NSError(domain: "HLSSegmentRecorder.Writer", code: -2)
        }

        writer.add(videoInput)
        writer.add(audioInput)

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput

        didStartSession = false
        firstVideoPTS = nil
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

    private func finishWriterLocked(completion: @escaping () -> Void) {
        guard let writer else {
            completion()
            return
        }

        guard writer.status == .writing else {
            completion()
            return
        }

        if lastAdjustedPTS.isValid {
            writer.endSession(atSourceTime: lastAdjustedPTS)
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting(completionHandler: completion)
    }

    private func cleanupWriterLocked() {
        writer = nil
        videoInput = nil
        audioInput = nil
        didStartSession = false
        firstVideoPTS = nil
        timeOffsetDelta = nil
        lastAdjustedPTS = .invalid
    }
}

extension HLSSegmentRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isWriting else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        startWriterIfNeeded(output: output, sampleBuffer: sampleBuffer)
        append(output: output, sampleBuffer: sampleBuffer)
    }

    private func startWriterIfNeeded(output: AVCaptureOutput, sampleBuffer: CMSampleBuffer) {
        guard output === videoOutput else { return }
        guard !didStartSession, let writer else { return }

        didStartSession = true
        guard writer.startWriting() else {
            print("startWriting failed:", writer.error as Any)
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.startSession(atSourceTime: startTimeOffset)
        firstVideoPTS = pts
        timeOffsetDelta = startTimeOffset - pts
    }

    private func append(output: AVCaptureOutput, sampleBuffer: CMSampleBuffer) {
        guard didStartSession,
              let writer,
              let videoInput,
              let audioInput,
              let timeOffsetDelta else { return }

        let adjustedSampleBuffer: CMSampleBuffer
        do {
            adjustedSampleBuffer = try sampleBuffer.offsettingTiming(by: timeOffsetDelta)
        } catch {
            adjustedSampleBuffer = sampleBuffer
        }

        let adjustedPTS = CMSampleBufferGetPresentationTimeStamp(adjustedSampleBuffer)
        if lastAdjustedPTS.isValid {
            if adjustedPTS > lastAdjustedPTS {
                lastAdjustedPTS = adjustedPTS
            }
        } else {
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
            print("append failed:", writer.status.rawValue, writer.error as Any)
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
        switch segmentType {
        case .initialization:
            onInitSegment?(segmentData)
        case .separable:
            segmentIndex += 1
            onMediaSegment?(segmentIndex, segmentData, segmentReport)
        @unknown default:
            break
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
