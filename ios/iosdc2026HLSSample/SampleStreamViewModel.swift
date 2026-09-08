import AVFoundation
import Foundation
import Observation
import UIKit

@MainActor
@Observable final class SampleStreamViewModel {
    enum State: Equatable {
        case idle
        case requestingPermission
        case ready
        case recording
        case starting
        case stopping
        case finished
        case error(String)
    }

    enum ServerState: Equatable {
        case unchecked
        case checking
        case connected
        case error(String)
    }

    private let streamer: any SampleStreaming
    private let photoSaver: any PhotoVideoSaving
    private let capturePermission: (@MainActor () async -> Bool)?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundExpired = false
    private var stopAfterStart = false
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
    private(set) var saveMessage: String?
    private(set) var saveErrorMessage: String?
    private(set) var isSaving = false
    private(set) var pendingVideos: [URL] = []

    var isBusy: Bool { state == .starting || state == .stopping || isSaving }

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
        case .idle, .requestingPermission, .starting, .stopping, .error:
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
        case .starting:
            return "開始中"
        case .stopping:
            return "終了処理中"
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
        case .starting, .stopping:
            return "hourglass"
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

    init(streamer: any SampleStreaming = SampleHLSStreamer(), photoSaver: any PhotoVideoSaving = PhotoVideoSaver(),
         capturePermission: (@MainActor () async -> Bool)? = nil) {
        self.streamer = streamer
        self.photoSaver = photoSaver
        self.capturePermission = capturePermission
    }

    func onAppear() async {
        refreshPendingVideos()
        guard state == .idle else { return }
        await prepare()
    }

    func checkServer(serverURLText: String) async {
        guard !isBusy, !isRecording else { return }
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
        guard !isBusy, state == .ready || state == .finished else { return }

        state = .starting
        saveMessage = nil
        saveErrorMessage = nil
        stopAfterStart = false
        guard await photoSaver.requestPermission() else {
            saveErrorMessage = "配信開始には写真への追加権限が必要です。設定アプリで許可してください。"
            state = .ready
            return
        }
        guard !stopAfterStart else { state = .ready; return }

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
            if stopAfterStart { await stopRecording() }
        } catch {
            serverState = .error(error.localizedDescription)
            operationErrorMessage = "録画開始に失敗しました: \(error.localizedDescription)"
            state = .ready
        }
    }

    func stopRecording() async {
        guard state == .recording else { return }
        state = .stopping
        beginBackgroundProtection()
        defer { endBackgroundProtection() }

        monitorTask?.cancel()
        monitorTask = nil

        do {
            let snapshot = try await streamer.stopRecording { [self] result in
                switch result {
                case .success(let url):
                    refreshPendingVideos()
                    if !backgroundExpired { await saveVideo(url) }
                case .failure(let error):
                    saveErrorMessage = error.localizedDescription
                }
            }
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
        if state == .starting { stopAfterStart = true }
        if state == .recording {
            await stopRecording()
        }
    }

    func onForeground() {
        refreshPendingVideos()
    }

    func retrySaving() async {
        guard !isBusy, !isRecording else { return }
        beginBackgroundProtection()
        defer { endBackgroundProtection() }
        refreshPendingVideos()
        for url in pendingVideos {
            guard !backgroundExpired else { break }
            await saveVideo(url)
            if saveErrorMessage != nil { break }
        }
    }

    private func saveVideo(_ url: URL) async {
        isSaving = true
        saveMessage = "写真へ保存中"
        saveErrorMessage = nil
        defer { isSaving = false; refreshPendingVideos() }
        do {
            try await photoSaver.save(url)
            saveMessage = "保存しました（フルHD・HEVC）"
        } catch {
            saveMessage = nil
            saveErrorMessage = "写真への保存に失敗しました: \(error.localizedDescription)"
        }
    }

    private func refreshPendingVideos() {
        do { pendingVideos = try photoSaver.pendingVideos() }
        catch { saveErrorMessage = "未保存動画の確認に失敗しました: \(error.localizedDescription)" }
    }

    private func beginBackgroundProtection() {
        guard backgroundTask == .invalid else { return }
        backgroundExpired = false
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish HLS and save video") { [weak self] in
            Task { @MainActor in
                self?.onBackgroundTimeExpired()
            }
        }
    }

    func onBackgroundTimeExpired() {
        guard state == .stopping || isSaving else { return }
        backgroundExpired = true
        operationErrorMessage = "終了処理の実行時間が切れました。アプリへ戻って結果を確認してください。"
        refreshPendingVideos()
        endBackgroundProtection()
    }

    private func endBackgroundProtection() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func prepare() async {
        state = .requestingPermission

        let allowed: Bool
        if let capturePermission {
            allowed = await capturePermission()
        } else {
            let cameraAllowed = await requestCameraPermission()
            let micAllowed = await requestMicrophonePermission()
            allowed = cameraAllowed && micAllowed
        }
        guard allowed else {
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
                    guard !Task.isCancelled, state == .recording else { return }
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
