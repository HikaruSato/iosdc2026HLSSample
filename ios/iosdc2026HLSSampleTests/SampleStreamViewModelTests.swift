import AVFoundation
import Foundation
import Testing
@testable import iosdc2026HLSSample

@MainActor
struct SampleStreamViewModelTests {
    @Test func photoPermissionIsRequiredBeforeStarting() async {
        let stream = FakeSampleStreamer()
        let photos = FakePhotoSaver()
        photos.allowed = false
        let vm = makeViewModel(stream, photos)
        await vm.onAppear()
        await vm.startRecording(serverURLText: "http://localhost:8080")
        #expect(stream.startCount == 0)
        #expect(vm.state == .ready)
        #expect(vm.saveErrorMessage != nil)
    }

    @Test func savesBeforeUploadCompletionAndPreventsDuplicateStop() async {
        let stream = FakeSampleStreamer()
        stream.suspendUpload = true
        let photos = FakePhotoSaver()
        let vm = makeViewModel(stream, photos)
        await vm.onAppear()
        await vm.startRecording(serverURLText: "http://localhost:8080")
        let stopping = Task { await vm.stopRecording() }
        while stream.uploadContinuation == nil { await Task.yield() }
        #expect(photos.saved == [stream.localURL])
        #expect(vm.state == .stopping)
        await vm.stopRecording()
        await vm.startRecording(serverURLText: "http://localhost:8080")
        #expect(stream.stopCount == 1)
        #expect(stream.startCount == 1)
        stream.uploadContinuation?.resume()
        await stopping.value
        #expect(vm.state == .finished)
        #expect(vm.saveMessage?.contains("保存しました") == true)
    }

    @Test func failedPhotoSaveCanBeRetriedWithoutStoppingAgain() async {
        let stream = FakeSampleStreamer()
        let photos = FakePhotoSaver()
        photos.failSave = true
        let vm = makeViewModel(stream, photos)
        await vm.onAppear()
        await vm.startRecording(serverURLText: "http://localhost:8080")
        await vm.stopRecording()
        #expect(vm.saveErrorMessage != nil)
        #expect(vm.pendingVideos == [stream.localURL])
        #expect(vm.playlistText.contains("ENDLIST"))
        photos.failSave = false
        await vm.retrySaving()
        #expect(vm.pendingVideos.isEmpty)
        #expect(vm.saveErrorMessage == nil)
        #expect(stream.stopCount == 1)
    }

    @Test func uploadFailureDoesNotPreventPhotoSave() async {
        let stream = FakeSampleStreamer()
        stream.uploadError = "HTTP failed"
        let photos = FakePhotoSaver()
        let vm = makeViewModel(stream, photos)
        await vm.onAppear()
        await vm.startRecording(serverURLText: "http://localhost:8080")
        await vm.stopRecording()
        #expect(photos.saved.count == 1)
        #expect(vm.operationErrorMessage?.contains("HTTP failed") == true)
        #expect(vm.saveErrorMessage == nil)
    }

    @Test func localFailureDoesNotDiscardSuccessfulHLSResult() async {
        let stream = FakeSampleStreamer()
        stream.localError = LocalRecordingError(message: "no audio")
        let photos = FakePhotoSaver()
        let vm = makeViewModel(stream, photos)
        await vm.onAppear()
        await vm.startRecording(serverURLText: "http://localhost:8080")
        await vm.stopRecording()
        #expect(photos.saved.isEmpty)
        #expect(vm.saveErrorMessage == "no audio")
        #expect(vm.playlistText.contains("ENDLIST"))
        #expect(vm.operationErrorMessage == nil)
    }

    @Test func nextRecordingCanStartAfterBothResultsComplete() async {
        let stream = FakeSampleStreamer()
        let photos = FakePhotoSaver()
        let vm = makeViewModel(stream, photos)
        await vm.onAppear()
        for _ in 0..<2 {
            await vm.startRecording(serverURLText: "http://localhost:8080")
            await vm.stopRecording()
        }
        #expect(stream.startCount == 2)
        #expect(stream.stopCount == 2)
        #expect(vm.state == .finished)
    }

    @Test func backgroundExpirationKeepsCompletedVideoForRetry() async {
        let stream = FakeSampleStreamer()
        stream.suspendLocal = true
        let photos = FakePhotoSaver()
        let vm = makeViewModel(stream, photos)
        await vm.onAppear()
        await vm.startRecording(serverURLText: "http://localhost:8080")
        let stopping = Task { await vm.stopIfNeeded() }
        while stream.localContinuation == nil { await Task.yield() }
        vm.onBackgroundTimeExpired()
        #expect(vm.state == .stopping)
        stream.localContinuation?.resume()
        await stopping.value
        #expect(photos.saved.isEmpty)
        #expect(vm.pendingVideos == [stream.localURL])
        #expect(vm.operationErrorMessage?.contains("実行時間") == true)
        vm.onForeground()
        await vm.retrySaving()
        #expect(photos.saved.count == 1)
    }

    @Test func startWhileAwaitingPermissionDoesNotStartTwice() async {
        let stream = FakeSampleStreamer()
        let photos = FakePhotoSaver()
        photos.suspendPermission = true
        let vm = makeViewModel(stream, photos)
        await vm.onAppear()
        let starting = Task { await vm.startRecording(serverURLText: "http://localhost:8080") }
        while photos.permissionContinuation == nil { await Task.yield() }
        await vm.startRecording(serverURLText: "http://localhost:8080")
        #expect(vm.state == .starting)
        photos.permissionContinuation?.resume()
        await starting.value
        #expect(stream.startCount == 1)
        await vm.stopRecording()
    }

    private func makeViewModel(_ stream: FakeSampleStreamer, _ photos: FakePhotoSaver) -> SampleStreamViewModel {
        photos.pending = [stream.localURL]
        return SampleStreamViewModel(streamer: stream, photoSaver: photos, capturePermission: { true })
    }
}

@MainActor
private final class FakePhotoSaver: PhotoVideoSaving {
    var allowed = true
    var failSave = false
    var pending: [URL] = []
    var saved: [URL] = []
    var suspendPermission = false
    var permissionContinuation: CheckedContinuation<Void, Never>?
    func requestPermission() async -> Bool {
        if suspendPermission { await withCheckedContinuation { permissionContinuation = $0 } }
        return allowed
    }
    func pendingVideos() throws -> [URL] { pending }
    func save(_ url: URL) async throws {
        if failSave { throw LocalRecordingError(message: "Photos failed") }
        saved.append(url)
        pending.removeAll { $0 == url }
    }
}

@MainActor
private final class FakeSampleStreamer: SampleStreaming {
    let captureSession = AVCaptureSession()
    let localURL = URL(fileURLWithPath: "/tmp/test-recording.mp4")
    var recordedSeconds = 1.0
    var startCount = 0
    var stopCount = 0
    var uploadError: String?
    var localError: LocalRecordingError?
    var suspendUpload = false
    var uploadContinuation: CheckedContinuation<Void, Never>?
    var suspendLocal = false
    var localContinuation: CheckedContinuation<Void, Never>?
    func startPreview() async throws {}
    func checkServer(baseURL: URL) async throws {}
    func startRecording(serverBaseURL: URL) async throws -> HLSStreamSnapshot {
        startCount += 1
        return snapshot(finished: false)
    }
    func stopRecording(onLocalRecording: @escaping @MainActor (LocalRecordingResult) async -> Void) async throws -> HLSStreamSnapshot {
        stopCount += 1
        if suspendLocal { await withCheckedContinuation { localContinuation = $0 } }
        await onLocalRecording(localError.map { .failure($0) } ?? .success(localURL))
        if suspendUpload {
            await withCheckedContinuation { uploadContinuation = $0 }
        }
        return snapshot(finished: true)
    }
    func currentSnapshot() async -> HLSStreamSnapshot? { snapshot(finished: false) }
    private func snapshot(finished: Bool) -> HLSStreamSnapshot {
        HLSStreamSnapshot(streamId: "test", viewerURL: URL(string: "http://localhost:8080")!,
            playlistURL: URL(string: "http://localhost:8080/playlist.m3u8")!,
            playlistText: finished && uploadError == nil ? "#EXT-X-ENDLIST\n" : "#EXTM3U\n",
            segmentCount: 1, errorMessage: uploadError)
    }
}
