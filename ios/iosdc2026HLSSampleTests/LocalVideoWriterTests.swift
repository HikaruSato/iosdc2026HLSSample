@preconcurrency import AVFoundation
import Testing
@testable import iosdc2026HLSSample

struct LocalVideoWriterTests {
    @Test func emptyRecordingIsNotPublishedAsCompletedMP4() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try LocalVideoWriter(directory: directory)
        let result = await finish(writer)
        guard case .failure = result else {
            Issue.record("空の録画は成功にしない")
            return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func generatesPortraitHEVCWithAudioFromSampleBuffers() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try LocalVideoWriter(directory: directory)
        // Writerのqueue confinementを守り、1秒間の映像と無音PCMを入力する。
        for index in 0..<30 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        writer.append(try videoSample(index), isVideo: true)
                        writer.append(try audioSample(index), isVideo: false)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try await Task.sleep(for: .milliseconds(34))
        }
        let url = try await finish(writer).get()
        #expect(!url.lastPathComponent.contains(".recording."))
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        let video = try #require(videos.first)
        #expect(audios.count == 1)
        #expect(try await video.load(.naturalSize) == CGSize(width: 1080, height: 1920))
        let formats = try await video.load(.formatDescriptions)
        #expect(formats.first.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_HEVC)
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 0.8 && duration < 1.2)
        let audio = try #require(audios.first)
        let audioFormats = try await audio.load(.formatDescriptions)
        #expect(audioFormats.first.map { CMFormatDescriptionGetMediaSubType($0) } == kAudioFormatMPEG4AAC)
    }

    private let queue = DispatchQueue(label: "test.local.writer")

    private func finish(_ writer: LocalVideoWriter) async -> LocalRecordingResult {
        await withCheckedContinuation { continuation in
            queue.async {
                writer.finish(on: queue) { continuation.resume(returning: $0) }
            }
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func videoSample(_ index: Int) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        try check(CVPixelBufferCreate(kCFAllocatorDefault, 1080, 1920,
            kCVPixelFormatType_32BGRA, nil, &pixelBuffer))
        let pixel = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        if let base = CVPixelBufferGetBaseAddress(pixel) {
            memset(base, 0, CVPixelBufferGetDataSize(pixel))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixel, formatDescriptionOut: &format))
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: Int64(3000 + index), timescale: 30),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixel, formatDescription: try #require(format),
            sampleTiming: &timing, sampleBufferOut: &sample))
        return try #require(sample)
    }

    private func audioSample(_ index: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format))
        let frames = 1470 // 44100 / 30
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: frames * 2, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: frames * 2, flags: 0,
            blockBufferOut: &block))
        let data = try #require(block)
        try check(CMBlockBufferFillDataBytes(with: 0, blockBuffer: data,
            offsetIntoDestination: 0, dataLength: frames * 2))
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100),
            presentationTimeStamp: CMTime(value: Int64(3000 + index), timescale: 30),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
            formatDescription: try #require(format), sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample))
        return try #require(sample)
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw LocalRecordingError(message: "fixture OSStatus \(status)") }
    }
}
