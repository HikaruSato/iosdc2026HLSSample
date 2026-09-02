@preconcurrency import AVFoundation
import Foundation

/// カメラとマイクのCMSampleBufferを、HLS用のfMP4 fragmentへ変換するRecorder。
///
/// データは次の順に流れる。
///
/// `AVCaptureSession → CMSampleBuffer → AVAssetWriter → HLSFragment`
///
/// CaptureSessionの状態は`sessionQueue`、Writerと時刻の状態は`writingQueue`へ閉じ込める。
/// このqueue confinementを契約として、delegateから参照される自身を`@unchecked Sendable`にしている。
final class HLSSegmentRecorder: NSObject, @unchecked Sendable {
    /// サンプルで説明する映像・音声品質とsegment間隔。
    struct Config: Sendable {
        /// 縦向き720p。Capture時の向きはconnection側で90度回転する。
        var videoSize = CGSize(width: 720, height: 1280)
        /// サンプルでは挙動を追いやすい固定bitrateを使う。
        var videoBitrate = 1_500_000
        var audioBitrate = 64_000
        /// Writerへ依頼するfragment間隔。実際の境界はkeyframeにより前後する。
        var segmentSeconds = 2.0
    }

    private let config: Config
    private let session = AVCaptureSession()

    // startRunning()は呼び出し元をblockするため、Appleはserial queueでの実行を推奨している。
    // CaptureSessionの構成・start・stopは、このqueueだけで行う。
    private let sessionQueue = DispatchQueue(label: "sample.capture.session.queue")
    // Video/Audio DataOutputのsetSampleBufferDelegate(_:queue:)へ渡す必要があるため、
    // callback先はserialなDispatchQueueとして持つ。Writerの状態とfragmentの連番もここで更新する。
    private let writingQueue = DispatchQueue(label: "sample.hls.writer.queue")

    // MovieFileOutputではなくDataOutputを使い、完成ファイルになる前のCMSampleBufferを受け取る。
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    // 以下のmutable stateはwritingQueueからだけ読み書きする。
    private var writer: AVAssetWriter?
    private var videoReceiver: AVAssetWriterInput.SampleBufferReceiver?
    private var audioReceiver: AVAssetWriterInput.SampleBufferReceiver?
    private var fragmentContinuation: AsyncThrowingStream<HLSFragment, Error>.Continuation?
    private var isWriting = false
    private var didStartSession = false
    private var timeOffsetDelta: CMTime?
    private var lastAdjustedPTS: CMTime = .invalid
    private var segmentIndex = 0

    // AACのprimingを含むCMSampleBufferにも余白を持たせるため、Writerのtimelineを10秒から始める。
    // VideoとAudioへ同じoffsetを加えることで、両者の相対的な時刻差は変えない。
    private let startTimeOffset = CMTime(value: 10, timescale: 1)

    /// 画面のプレビュー表示に使うCaptureSession。
    var captureSession: AVCaptureSession {
        session
    }

    init(config: Config) {
        self.config = config
        super.init()
    }

    // MARK: - Capture lifecycle

    /// カメラとマイクを構成し、CMSampleBufferの受信を開始する。
    /// HLS Writerは``startRecording()``を呼ぶまで作らない。
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

    /// Writerを準備し、生成されるfragmentを順番に受け取るstreamを返す。
    /// streamを先に作ってから`isWriting`を有効にするため、最初のinit fragmentを取りこぼさない。
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

    /// Captureを止めてCMSampleBuffer callbackをdrainした後、Writerとfragment streamを閉じる。
    func stop() async {
        // 新しいCMSampleBufferがwritingQueueへ追加されなくなるまで、先にCaptureSessionの停止を待つ。
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                continuation.resume()
            }
        }

        // sessionQueueより前に投入済みのCMSampleBufferはserialなwritingQueue上で処理済みになる。
        // その後finishWritingし、最後のfragment callbackを受け取ってからstreamを終了する。
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

    // MARK: - CaptureSession setup

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
        try audioSession.setActive(true)
    }

    private func setupCaptureSessionLocked() throws {
        // Previewの再開時に同じinput/outputを二重追加しないよう、構成は初回だけ行う。
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
        // リアルタイム配信では遅れたframeを溜めず、現在の映像へ追いつくことを優先する。
        videoOutput.alwaysDiscardsLateVideoFrames = true
        // AppleのAPI要件に従い、VideoとAudioのdelegateにはserial queueを指定する。
        // 両方を同じwritingQueueへ渡し、Writerへappendする順序も1か所で管理する。
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

    // MARK: - Writer setup

    private func setupWriterLocked() throws {
        cleanupWriterLocked()

        // output URLを持たないWriterにdelegateを設定し、完成したfMP4 fragmentをDataで受け取る。
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        // Apple HLS向けのfragmented MP4構成を選ぶ。
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        // 2秒は希望値。実際のsegment境界は次のkeyframeまで前後することがある。
        writer.preferredOutputSegmentInterval = CMTime(
            seconds: config.segmentSeconds,
            preferredTimescale: 600
        )
        writer.initialSegmentStartTime = startTimeOffset
        writer.delegate = self

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings())
        // ファイル変換ではなく撮影中の入力なので、リアルタイムsourceであることをWriterへ伝える。
        videoInput.expectsMediaDataInRealTime = true

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings())
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw HLSSegmentRecorderError.cannotAddWriterInputs
        }

        // inputReceiver(for:)はInputをWriterへ接続し、CMSampleBufferを書き込む窓口を返す。
        let videoReceiver = writer.inputReceiver(for: videoInput)
        let audioReceiver = writer.inputReceiver(for: audioInput)

        self.writer = writer
        self.videoReceiver = videoReceiver
        self.audioReceiver = audioReceiver
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
                // segment先頭付近にIDRを用意できるよう、segment間隔に合わせてkeyframeを要求する。
                AVVideoMaxKeyFrameIntervalDurationKey: config.segmentSeconds,
                // frameの表示順とdecode順を一致させ、segment単位の再生を単純にする。
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

    // MARK: - Writer completion

    private func finishWriterLocked(completion: @escaping @Sendable (Error?) -> Void) {
        guard let writer else {
            completion(nil)
            return
        }

        switch writer.status {
        case .writing:
            // 開始時と同じ補正後timelineでmedia rangeを閉じる。
            if lastAdjustedPTS.isValid {
                writer.endSession(atSourceTime: lastAdjustedPTS)
            }

            videoReceiver?.finish()
            audioReceiver?.finish()
            // finishWritingにより、残っている最後のsegmentがdelegateへ届く可能性がある。
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

    private func failWriterLocked(action: String, underlyingError: Error? = nil) {
        let error = HLSSegmentRecorderError.writerFailed(
            action: action,
            reason: writer?.error?.localizedDescription ?? underlyingError?.localizedDescription
        )
        if writer?.status == .writing {
            writer?.cancelWriting()
        }
        isWriting = false
        // printだけで終わらせず、consumerまで同じエラーを届ける。
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
        videoReceiver = nil
        audioReceiver = nil
        didStartSession = false
        timeOffsetDelta = nil
        lastAdjustedPTS = .invalid
    }
}

// MARK: - Camera and microphone CMSampleBuffer callbacks

extension HLSSegmentRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // 録画中かつ利用可能なCMSampleBufferだけをWriterへ流し、状態遷移を単純に保つ。
        guard isWriting, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        startWriterIfNeeded(output: output, sampleBuffer: sampleBuffer)
        append(output: output, sampleBuffer: sampleBuffer)
    }

    private func startWriterIfNeeded(output: AVCaptureOutput, sampleBuffer: CMSampleBuffer) {
        // 最初のVideo PTSを共通の基準にする。Audioが先に届いても開始はしない。
        guard output === videoOutput else { return }
        guard !didStartSession, let writer else { return }

        do {
            try writer.start()
        } catch {
            failWriterLocked(action: "start", underlyingError: error)
            return
        }

        didStartSession = true
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.startSession(atSourceTime: startTimeOffset)
        // Capture clock上のPTSを、10秒から始まるWriter timelineへ平行移動する。
        timeOffsetDelta = startTimeOffset - pts
    }

    private func append(output: AVCaptureOutput, sampleBuffer: CMSampleBuffer) {
        guard didStartSession,
              let videoReceiver,
              let audioReceiver,
              let timeOffsetDelta else { return }

        let adjustedSampleBuffer: CMSampleBuffer
        do {
            // 映像・音声の全CMSampleBufferへ同じdeltaを適用し、A/V syncを保つ。
            adjustedSampleBuffer = try sampleBuffer.offsettingTiming(by: timeOffsetDelta)
        } catch {
            failWriterLocked(action: "adjust sample timing")
            return
        }

        do {
            // このcopyはwritingQueue内で以後参照しないため、Receiverへ所有権を渡してよい。
            nonisolated(unsafe) let transferableSampleBuffer = adjustedSampleBuffer
            let readySampleBuffer = CMReadySampleBuffer(unsafeBuffer: transferableSampleBuffer)
            // appendImmediatelyはWriterを待たない。受け入れ不可ならfalseを返すため、そのCMSampleBufferを落とす。
            let didAppend = if output === videoOutput {
                try videoReceiver.appendImmediately(readySampleBuffer)
            } else {
                try audioReceiver.appendImmediately(readySampleBuffer)
            }
            guard didAppend else { return }

            // endSessionへ渡すのは、Receiverが実際に受け入れた最後のPTS。
            let adjustedPTS = CMSampleBufferGetPresentationTimeStamp(adjustedSampleBuffer)
            if !lastAdjustedPTS.isValid || adjustedPTS > lastAdjustedPTS {
                lastAdjustedPTS = adjustedPTS
            }
        } catch {
            failWriterLocked(action: "append", underlyingError: error)
        }
    }
}

// MARK: - HLS fragment output

extension HLSSegmentRecorder: AVAssetWriterDelegate {
    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        // delegateが呼ばれるqueueに依存せず、連番とContinuationの操作をwritingQueueへ戻す。
        let duration = segmentDuration(from: segmentReport)

        writingQueue.async {
            guard let continuation = self.fragmentContinuation else { return }

            switch segmentType {
            case .initialization:
                // EXT-X-MAPから参照されるinit.mp4。配信ごとに最初の1回だけ生成される。
                continuation.yield(.initialization(segmentData))

            case .separable:
                // 単独で分離可能なmedia segmentへ、playlistと同じsequenceを付ける。
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
        // EXTINFには希望値ではなく、Writerが報告したVideo trackの実時間を使う。
        guard let track = report?.trackReports.first(where: { $0.mediaType == .video }) else {
            return config.segmentSeconds
        }

        let duration = track.duration.seconds
        return duration.isFinite && duration > 0 ? duration : config.segmentSeconds
    }
}

/// CaptureSessionまたはWriterの準備・実行に失敗した理由。
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

// MARK: - Sample timing correction

private extension CMSampleBuffer {
    /// CMSampleBufferの内容は変えず、PTSと有効なDTSを同じ量だけ平行移動したコピーを作る。
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
        // output PTSも同じtimelineへ合わせ、Writerが参照する時刻情報を一貫させる。
        try copied.setOutputPresentationTimeStamp(copied.outputPresentationTimeStamp + offset)
        return copied
    }
}
