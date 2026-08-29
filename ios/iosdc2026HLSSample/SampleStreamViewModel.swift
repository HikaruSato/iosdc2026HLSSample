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

    enum ServerState: Equatable {
        case unchecked
        case checking
        case connected
        case error(String)
    }

    private let streamer: SampleHLSStreamer
    @ObservationIgnored private var monitorTask: Task<Void, Never>?

    private(set) var state: State = .idle
    private(set) var serverState: ServerState = .unchecked
    private(set) var streamId: String?
    private(set) var viewerURL: URL?
    private(set) var playlistURL: URL?
    private(set) var playlistText = ""
    private(set) var segmentCount = 0
    private(set) var elapsedSeconds = 0.0
    private(set) var operationErrorMessage: String?

    var captureSession: AVCaptureSession {
        streamer.captureSession
    }

    var errorMessage: String? {
        if case let .error(message) = state {
            return message
        }
        return operationErrorMessage
    }

    var serverErrorMessage: String? {
        if case let .error(message) = serverState {
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

    var serverStateText: String {
        switch serverState {
        case .unchecked:
            return "未確認"
        case .checking:
            return "確認中"
        case .connected:
            return "接続済み"
        case .error:
            return "接続エラー"
        }
    }

    var serverStateSystemImage: String {
        switch serverState {
        case .unchecked:
            return "network"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .connected:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var elapsedText: String {
        String(format: "%.1f", elapsedSeconds)
    }

    init(streamer: SampleHLSStreamer = SampleHLSStreamer()) {
        self.streamer = streamer
    }

    func onAppear() async {
        guard state == .idle else { return }
        await prepare()
    }

    func checkServer(serverURLText: String) async {
        operationErrorMessage = nil
        serverState = .checking
        elapsedSeconds = 0
        segmentCount = 0
        playlistText = ""

        do {
            let serverURL = try makeServerURL(from: serverURLText)
            try await streamer.checkServer(baseURL: serverURL)
            serverState = .connected
        } catch {
            serverState = .error(error.localizedDescription)
        }
    }

    func startRecording(serverURLText: String) async {
        guard state == .ready || state == .finished else { return }

        operationErrorMessage = nil
        serverState = .checking

        do {
            let serverURL = try makeServerURL(from: serverURLText)
            try await streamer.startPreview()
            let snapshot = try await streamer.startRecording(serverBaseURL: serverURL)
            apply(snapshot)
            serverState = .connected
            state = .recording
            startMonitoring()
        } catch {
            serverState = .error(error.localizedDescription)
            operationErrorMessage = "録画開始に失敗しました: \(error.localizedDescription)"
            state = .ready
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

            if let uploadError = snapshot.errorMessage {
                operationErrorMessage = "アップロードに失敗しました: \(uploadError)"
            }
        } catch {
            operationErrorMessage = "録画停止に失敗しました: \(error.localizedDescription)"
            state = .finished
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

                if let snapshot = await streamer.currentSnapshot() {
                    apply(snapshot)
                    if let uploadError = snapshot.errorMessage {
                        operationErrorMessage = "アップロードに失敗しました: \(uploadError)"
                    }
                }

                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func apply(_ snapshot: HLSStreamSnapshot) {
        streamId = snapshot.streamId
        viewerURL = snapshot.viewerURL
        playlistURL = snapshot.playlistURL
        playlistText = snapshot.playlistText
        segmentCount = snapshot.segmentCount
    }

    private func makeServerURL(from text: String) throws -> URL {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedText), !trimmedText.isEmpty else {
            throw HTTPHLSClientError.invalidServerURL
        }
        return url
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
