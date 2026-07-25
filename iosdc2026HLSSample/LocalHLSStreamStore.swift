import Foundation

struct LocalHLSStream: Identifiable, Equatable, Sendable {
    let streamId: String
    let createdAt: Date
    let directoryURL: URL
    let playlistURL: URL
    let webPreviewURL: URL
    var segmentCount: Int

    var id: String {
        streamId
    }
}

struct LocalHLSStreamSnapshot: Equatable, Sendable {
    let stream: LocalHLSStream
    let playlistText: String
    let segmentCount: Int
}

enum LocalHLSStreamError: LocalizedError {
    case noActiveStream
    case missingStream(String)

    var errorDescription: String? {
        switch self {
        case .noActiveStream:
            return "録画中のstreamがありません"
        case let .missingStream(streamId):
            return "streamが見つかりません: \(streamId)"
        }
    }
}

actor LocalHLSStreamStore {
    private let fileManager: FileManager
    private let rootDirectory: URL
    private var manifests: [String: LocalHLSManifest] = [:]
    private var streams: [String: LocalHLSStream] = [:]

    init(fileManager: FileManager = .default, rootDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
    }

    func createStream(targetDurationSec: Int) throws -> LocalHLSStream {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        let streamId = Self.makeStreamId()
        let directoryURL = rootDirectory.appendingPathComponent(streamId, isDirectory: true)
        let segmentDirectoryURL = directoryURL.appendingPathComponent("seg", isDirectory: true)
        try fileManager.createDirectory(at: segmentDirectoryURL, withIntermediateDirectories: true)

        let playlistURL = directoryURL.appendingPathComponent("playlist.m3u8")
        let webPreviewURL = directoryURL.appendingPathComponent("index.html")
        let manifest = LocalHLSManifest(targetDurationSec: targetDurationSec)

        try manifest.text.write(
            to: playlistURL,
            atomically: true,
            encoding: .utf8
        )
        try Self.webPreviewHTML.write(
            to: webPreviewURL,
            atomically: true,
            encoding: .utf8
        )

        let stream = LocalHLSStream(
            streamId: streamId,
            createdAt: .now,
            directoryURL: directoryURL,
            playlistURL: playlistURL,
            webPreviewURL: webPreviewURL,
            segmentCount: 0
        )

        manifests[streamId] = manifest
        streams[streamId] = stream
        return stream
    }

    func saveInitSegment(_ data: Data, for stream: LocalHLSStream) throws {
        let fileURL = stream.directoryURL.appendingPathComponent("init.mp4")

        // 本番ではこのDataをS3の init.mp4 へアップロードする。
        try data.write(to: fileURL, options: [.atomic])
    }

    func saveMediaSegment(
        seq: Int,
        data: Data,
        durationSec: Double,
        for stream: LocalHLSStream
    ) throws {
        let segmentURL = stream.directoryURL
            .appendingPathComponent("seg", isDirectory: true)
            .appendingPathComponent("\(LocalHLSManifest.paddedSequence(seq)).m4s")

        // 本番ではこのDataをS3の seg/000001.m4s のようなobjectへアップロードする。
        try data.write(to: segmentURL, options: [.atomic])

        var manifest = try manifestForUpdate(stream: stream)

        // 本番ではS3 PUT成功後にcommit APIを呼び、playlistへ見せるsegmentとして公開する。
        manifest.addSegment(seq: seq, durationSec: durationSec)
        try write(manifest: manifest, for: stream)
    }

    func finish(stream: LocalHLSStream) throws {
        var manifest = try manifestForUpdate(stream: stream)

        // 本番では最後のcommit(isLast: true)でS3上のplaylistへ #EXT-X-ENDLIST を反映する。
        manifest.finish()
        try write(manifest: manifest, for: stream)
    }

    func snapshot(for stream: LocalHLSStream) throws -> LocalHLSStreamSnapshot {
        guard let manifest = manifests[stream.streamId],
              var storedStream = streams[stream.streamId] else {
            throw LocalHLSStreamError.missingStream(stream.streamId)
        }

        storedStream.segmentCount = manifest.segmentCount
        return LocalHLSStreamSnapshot(
            stream: storedStream,
            playlistText: manifest.text,
            segmentCount: manifest.segmentCount
        )
    }

    private func manifestForUpdate(stream: LocalHLSStream) throws -> LocalHLSManifest {
        guard let manifest = manifests[stream.streamId] else {
            throw LocalHLSStreamError.missingStream(stream.streamId)
        }
        return manifest
    }

    private func write(manifest: LocalHLSManifest, for stream: LocalHLSStream) throws {
        try manifest.text.write(
            to: stream.playlistURL,
            atomically: true,
            encoding: .utf8
        )

        manifests[stream.streamId] = manifest

        if var storedStream = streams[stream.streamId] {
            storedStream.segmentCount = manifest.segmentCount
            streams[stream.streamId] = storedStream
        }
    }

    private static func defaultRootDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HLSStreams", isDirectory: true)
    }

    private static func makeStreamId() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "stream-\(formatter.string(from: .now))-\(UUID().uuidString.prefix(8))"
    }

    private static let webPreviewHTML = """
    <!doctype html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        html, body { margin: 0; height: 100%; background: #111; color: white; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
        body { display: grid; place-items: center; }
        main { width: min(100vw, 720px); padding: 16px; box-sizing: border-box; }
        video { width: 100%; background: black; border-radius: 8px; }
        pre { white-space: pre-wrap; font-size: 12px; color: #aaa; }
      </style>
    </head>
    <body>
      <main>
        <video controls playsinline src="playlist.m3u8"></video>
        <pre>playlist.m3u8 / init.mp4 / seg/*.m4s</pre>
      </main>
    </body>
    </html>
    """
}
