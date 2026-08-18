import AVFoundation
import Foundation
import Observation

@MainActor
@Observable final class SampleStreamViewModel {
    enum State: Equatable {
        case idle
        case requestingPermission
        case ready
        case recording
        case finished
        case error(String)
    }

    private let streamer: LocalHLSStreamer
    @ObservationIgnored private var monitorTask: Task<Void, Never>?

    private(set) var state: State = .idle
    private(set) var streamId: String?
    private(set) var outputDirectoryURL: URL?
    private(set) var outputDirectoryText: String?
    private(set) var playbackURL: URL?
    private(set) var webPreviewURL: URL?
    private(set) var playlistText = ""
    private(set) var segmentCount = 0
    private(set) var elapsedSeconds = 0.0
    var isShowingPlayer = false
    var isShowingWebPreview = false

    var captureSession: AVCaptureSession {
        streamer.captureSession
    }

    var errorMessage: String? {
        if case let .error(message) = state {
            return message
        }
        return nil
    }

    var isRecording: Bool {
        state == .recording
    }

    var canToggleRecording: Bool {
        switch state {
        case .ready, .recording, .finished:
            return true
        case .idle, .requestingPermission, .error:
            return false
        }
    }

    var stateText: String {
        switch state {
        case .idle:
            return "Idle"
        case .requestingPermission:
            return "Permission"
        case .ready:
            return "Ready"
        case .recording:
            return "REC"
        case .finished:
            return "Finished"
        case .error:
            return "Error"
        }
    }

    var stateSystemImage: String {
        switch state {
        case .idle:
            return "circle"
        case .requestingPermission:
            return "hourglass"
        case .ready:
            return "checkmark.circle"
        case .recording:
            return "record.circle"
        case .finished:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    var elapsedText: String {
        String(format: "%.1f", elapsedSeconds)
    }

    init(streamer: LocalHLSStreamer = LocalHLSStreamer()) {
        self.streamer = streamer
    }

    func onAppear() async {
        guard state == .idle else { return }
        await prepare()
    }

    func startRecording() async {
        guard state == .ready || state == .finished else { return }

        do {
            try await streamer.startPreview()
            let snapshot = try await streamer.startRecording()
            apply(snapshot)
            state = .recording
            startMonitoring()
        } catch {
            state = .error("録画開始に失敗しました: \(error.localizedDescription)")
        }
    }

    func stopRecording() async {
        guard state == .recording else { return }

        monitorTask?.cancel()
        monitorTask = nil

        do {
            let snapshot = try await streamer.stopRecording()
            apply(snapshot)
            state = .finished
        } catch {
            state = .error("録画停止に失敗しました: \(error.localizedDescription)")
        }
    }

    func stopIfNeeded() async {
        if state == .recording {
            await stopRecording()
        }
    }

    private func prepare() async {
        state = .requestingPermission

        let cameraAllowed = await requestCameraPermission()
        let micAllowed = await requestMicrophonePermission()

        guard cameraAllowed, micAllowed else {
            state = .error("カメラまたはマイクの権限がありません")
            return
        }

        do {
            try await streamer.startPreview()
            state = .ready
        } catch {
            state = .error("カメラ起動に失敗しました: \(error.localizedDescription)")
        }
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task {
            while !Task.isCancelled {
                elapsedSeconds = streamer.recordedSeconds

                if let snapshot = try? await streamer.currentSnapshot() {
                    apply(snapshot)
                }

                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func apply(_ snapshot: LocalHLSStreamSnapshot) {
        streamId = snapshot.stream.streamId
        outputDirectoryURL = snapshot.stream.directoryURL
        outputDirectoryText = snapshot.stream.directoryURL.path
        playbackURL = snapshot.stream.playlistURL
        webPreviewURL = snapshot.stream.webPreviewURL
        playlistText = snapshot.playlistText
        segmentCount = snapshot.segmentCount
    }

    private func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) {
                    continuation.resume(returning: $0)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) {
                    continuation.resume(returning: $0)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
