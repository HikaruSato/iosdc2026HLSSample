import AVFoundation
import Photos

@MainActor
protocol PhotoVideoSaving {
    func requestPermission() async -> Bool
    func pendingVideos() throws -> [URL]
    func save(_ url: URL) async throws
}

@MainActor
final class PhotoVideoSaver: PhotoVideoSaving {
    private let savedFilesKey = "photoLibrarySavedLocalFiles"

    private var savedFiles: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: savedFilesKey) ?? [])
    }
    func requestPermission() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let status = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .addOnly) : current
        return status == .authorized || status == .limited
    }

    func pendingVideos() throws -> [URL] {
        try LocalRecordingFiles.pending().filter { !savedFiles.contains($0.lastPathComponent) }
    }

    func save(_ url: URL) async throws {
        guard !savedFiles.contains(url.lastPathComponent) else { return }
        guard await requestPermission() else {
            throw LocalRecordingError(message: "設定アプリで写真への追加を許可してください")
        }
        let asset = AVURLAsset(url: url)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard let video = videos.first, !audios.isEmpty,
              try await asset.load(.duration).seconds > 0 else {
            throw LocalRecordingError(message: "映像・音声の揃った動画ではありません")
        }
        let size = try await video.load(.naturalSize)
        let formats = try await video.load(.formatDescriptions)
        guard size.width == 1080, size.height == 1920,
              formats.first.map({ CMFormatDescriptionGetMediaSubType($0) }) == kCMVideoCodecType_HEVC else {
            throw LocalRecordingError(message: "保存動画が1080×1920・HEVCではありません")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
        // 写真保存成功後は再試行対象から外し、削除失敗による重複保存を防ぐ。
        var completed = savedFiles
        completed.insert(url.lastPathComponent)
        UserDefaults.standard.set(Array(completed), forKey: savedFilesKey)
        try? FileManager.default.removeItem(at: url)
    }
}
