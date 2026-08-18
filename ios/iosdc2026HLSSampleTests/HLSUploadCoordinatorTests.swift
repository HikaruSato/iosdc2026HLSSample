import Foundation
import Testing
@testable import iosdc2026HLSSample

struct HLSUploadCoordinatorTests {
    @Test func uploadsSegmentsBeforePublishingEachPlaylist() async throws {
        let client = FakeHTTPHLSClient()
        let channel = HLSUploadEventChannel()
        let coordinator = HLSUploadCoordinator(
            client: client,
            streamId: "stream-1",
            targetDurationSec: 2
        )
        let consumeTask = Task {
            await coordinator.consume(channel.stream, channel: channel)
        }

        channel.yield(.initialization(Data([0x00])))
        channel.yield(.media(seq: 1, data: Data([0x01]), durationSec: 2))
        channel.yield(.media(seq: 2, data: Data([0x02]), durationSec: 1.5))
        channel.finish()
        await consumeTask.value

        let operations = await client.operations
        #expect(operations.count == 6)
        #expect(operations[0].name == "init")
        #expect(operations[1].name == "segment-1")
        #expect(operations[2].name == "playlist")
        #expect(operations[3].name == "segment-2")
        #expect(operations[4].name == "playlist")
        #expect(operations[5].name == "playlist")

        let playlists = operations.compactMap(\.playlistText)
        #expect(playlists.count == 3)
        #expect(playlists[0].contains("seg/000001.m4s"))
        #expect(!playlists[0].contains("seg/000002.m4s"))
        #expect(!playlists[0].contains("#EXT-X-ENDLIST"))
        #expect(playlists[1].contains("seg/000002.m4s"))
        #expect(!playlists[1].contains("#EXT-X-ENDLIST"))
        #expect(playlists[2].hasSuffix("#EXT-X-ENDLIST\n"))

        let snapshot = await coordinator.snapshot(pendingUploadCount: channel.pendingCount)
        #expect(snapshot.segmentCount == 2)
        #expect(snapshot.pendingUploadCount == 0)
        #expect(snapshot.isFinished)
        #expect(snapshot.errorMessage == nil)
    }

    @Test func failedSegmentIsRetriedWithoutPublishingPlaylist() async throws {
        let client = FakeHTTPHLSClient(mediaFailuresRemaining: 3)
        let channel = HLSUploadEventChannel()
        let coordinator = HLSUploadCoordinator(
            client: client,
            streamId: "stream-2",
            targetDurationSec: 2
        )
        let consumeTask = Task {
            await coordinator.consume(channel.stream, channel: channel)
        }

        channel.yield(.initialization(Data([0x00])))
        channel.yield(.media(seq: 1, data: Data([0x01]), durationSec: 2))
        channel.finish()
        await consumeTask.value

        let operations = await client.operations
        #expect(operations.filter { $0.name == "segment-1" }.count == 3)
        #expect(!operations.contains { $0.name == "playlist" })

        let snapshot = await coordinator.snapshot(pendingUploadCount: channel.pendingCount)
        #expect(snapshot.segmentCount == 0)
        #expect(!snapshot.isFinished)
        #expect(snapshot.errorMessage != nil)
    }
}

private struct UploadOperation: Sendable {
    let name: String
    let playlistText: String?
}

private enum FakeUploadError: Error {
    case failed
}

private actor FakeHTTPHLSClient: HTTPHLSClientProtocol {
    nonisolated let viewerURL = URL(string: "http://127.0.0.1:8080")!

    private(set) var operations: [UploadOperation] = []
    private var mediaFailuresRemaining: Int

    init(mediaFailuresRemaining: Int = 0) {
        self.mediaFailuresRemaining = mediaFailuresRemaining
    }

    func healthCheck() async throws {}

    nonisolated func playlistURL(streamId: String) -> URL {
        viewerURL
            .appendingPathComponent("streams")
            .appendingPathComponent(streamId)
            .appendingPathComponent("playlist.m3u8")
    }

    func putInitSegment(streamId: String, data: Data) async throws {
        operations.append(UploadOperation(name: "init", playlistText: nil))
    }

    func putMediaSegment(streamId: String, seq: Int, data: Data) async throws {
        operations.append(UploadOperation(name: "segment-\(seq)", playlistText: nil))
        if mediaFailuresRemaining > 0 {
            mediaFailuresRemaining -= 1
            throw FakeUploadError.failed
        }
    }

    func putPlaylist(streamId: String, text: String) async throws {
        operations.append(UploadOperation(name: "playlist", playlistText: text))
    }
}
