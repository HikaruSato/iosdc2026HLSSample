import Foundation
import Testing
@testable import iosdc2026HLSSample

struct HLSStreamPublisherTests {
    @Test func uploadsSegmentsBeforePublishingEachPlaylist() async throws {
        let client = FakeHLSClient()
        let publisher = HLSStreamPublisher(
            client: client,
            streamId: "stream-1",
            targetDurationSec: 2
        )

        await publisher.publish(fragmentStream([
            .initialization(Data([0x00])),
            .media(sequence: 1, data: Data([0x01]), duration: 2),
            .media(sequence: 2, data: Data([0x02]), duration: 1.5)
        ]))

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
        #expect(playlists[1].contains("#EXTINF:1.500,\nseg/000002.m4s"))
        #expect(!playlists[1].contains("#EXT-X-ENDLIST"))
        #expect(playlists[2].hasSuffix("#EXT-X-ENDLIST\n"))

        let snapshot = await publisher.snapshot()
        #expect(snapshot.segmentCount == 2)
        #expect(snapshot.playlistText.hasSuffix("#EXT-X-ENDLIST\n"))
        #expect(snapshot.errorMessage == nil)
    }

    @Test func failedSegmentIsRetriedWithoutPublishingPlaylist() async throws {
        let client = FakeHLSClient(mediaFailuresRemaining: 3)
        let publisher = HLSStreamPublisher(
            client: client,
            streamId: "stream-2",
            targetDurationSec: 2
        )

        await publisher.publish(fragmentStream([
            .initialization(Data([0x00])),
            .media(sequence: 1, data: Data([0x01]), duration: 2)
        ]))

        let operations = await client.operations
        #expect(operations.filter { $0.name == "segment-1" }.count == 3)
        #expect(!operations.contains { $0.name == "playlist" })

        let snapshot = await publisher.snapshot()
        #expect(snapshot.segmentCount == 0)
        #expect(!snapshot.playlistText.contains("#EXT-X-ENDLIST"))
        #expect(snapshot.errorMessage != nil)
    }

    @Test func recorderFailureIsStoredWithoutPublishingEndlist() async throws {
        let client = FakeHLSClient()
        let publisher = HLSStreamPublisher(
            client: client,
            streamId: "stream-3",
            targetDurationSec: 2
        )
        let fragments = AsyncThrowingStream<HLSFragment, Error>.makeStream()
        fragments.continuation.yield(.initialization(Data([0x00])))
        fragments.continuation.finish(throwing: FakeRecorderError.failed)

        await publisher.publish(fragments.stream)

        let operations = await client.operations
        #expect(operations.map(\.name) == ["init"])

        let snapshot = await publisher.snapshot()
        #expect(snapshot.errorMessage == FakeRecorderError.failed.localizedDescription)
        #expect(!snapshot.playlistText.contains("#EXT-X-ENDLIST"))
    }
}

private func fragmentStream(
    _ fragments: [HLSFragment]
) -> AsyncThrowingStream<HLSFragment, Error> {
    let stream = AsyncThrowingStream<HLSFragment, Error>.makeStream()
    for fragment in fragments {
        stream.continuation.yield(fragment)
    }
    stream.continuation.finish()
    return stream.stream
}

private struct UploadOperation: Sendable {
    let name: String
    let playlistText: String?
}

private enum FakeUploadError: Error {
    case failed
}

private enum FakeRecorderError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Recorder failed"
    }
}

private actor FakeHLSClient: HLSClient {
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
