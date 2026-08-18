import Foundation

enum HLSUploadEvent: Sendable {
    case initialization(Data)
    case media(seq: Int, data: Data, durationSec: Double)
}

struct HLSUploadSnapshot: Equatable, Sendable {
    let streamId: String
    let viewerURL: URL
    let playlistURL: URL
    let playlistText: String
    let segmentCount: Int
    let pendingUploadCount: Int
    let isFinished: Bool
    let errorMessage: String?
}

final class HLSUploadEventChannel: @unchecked Sendable {
    let stream: AsyncStream<HLSUploadEvent>

    private let continuation: AsyncStream<HLSUploadEvent>.Continuation
    private let lock = NSLock()
    private var isFinished = false
    private var queuedEventCount = 0

    init() {
        let pair = AsyncStream.makeStream(
            of: HLSUploadEvent.self,
            bufferingPolicy: .unbounded
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    var pendingCount: Int {
        lock.withLock { queuedEventCount }
    }

    func yield(_ event: HLSUploadEvent) {
        lock.withLock {
            guard !isFinished else { return }
            queuedEventCount += 1

            switch continuation.yield(event) {
            case .enqueued:
                break
            case .dropped, .terminated:
                queuedEventCount -= 1
            @unknown default:
                queuedEventCount -= 1
            }
        }
    }

    func markProcessed() {
        lock.withLock {
            queuedEventCount = max(0, queuedEventCount - 1)
        }
    }

    func finish() {
        lock.withLock {
            guard !isFinished else { return }
            isFinished = true
            continuation.finish()
        }
    }
}

actor HLSUploadCoordinator {
    private let client: HTTPHLSClientProtocol
    private let streamId: String
    private var manifest: HLSManifest

    private var didUploadInitSegment = false
    private var isFinished = false
    private var errorMessage: String?

    init(
        client: HTTPHLSClientProtocol,
        streamId: String,
        targetDurationSec: Int
    ) {
        self.client = client
        self.streamId = streamId
        manifest = HLSManifest(targetDurationSec: targetDurationSec)
    }

    func consume(
        _ events: AsyncStream<HLSUploadEvent>,
        channel: HLSUploadEventChannel
    ) async {
        for await event in events {
            if errorMessage == nil {
                do {
                    try await process(event)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            channel.markProcessed()
        }

        guard errorMessage == nil else { return }
        guard didUploadInitSegment else {
            errorMessage = "init.mp4が生成されませんでした"
            return
        }
        guard manifest.segmentCount > 0 else {
            errorMessage = "media segmentが生成されませんでした"
            return
        }

        var finalManifest = manifest
        finalManifest.finish()

        do {
            try await retrying {
                try await client.putPlaylist(streamId: streamId, text: finalManifest.text)
            }
            manifest = finalManifest
            isFinished = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func snapshot(pendingUploadCount: Int) -> HLSUploadSnapshot {
        HLSUploadSnapshot(
            streamId: streamId,
            viewerURL: client.viewerURL,
            playlistURL: client.playlistURL(streamId: streamId),
            playlistText: manifest.text,
            segmentCount: manifest.segmentCount,
            pendingUploadCount: pendingUploadCount,
            isFinished: isFinished,
            errorMessage: errorMessage
        )
    }

    private func process(_ event: HLSUploadEvent) async throws {
        switch event {
        case let .initialization(data):
            guard !didUploadInitSegment else { return }
            try await retrying {
                try await client.putInitSegment(streamId: streamId, data: data)
            }
            didUploadInitSegment = true

        case let .media(seq, data, durationSec):
            guard didUploadInitSegment else {
                throw HLSUploadError.mediaBeforeInitialization
            }

            try await retrying {
                try await client.putMediaSegment(streamId: streamId, seq: seq, data: data)
            }

            var nextManifest = manifest
            nextManifest.addSegment(seq: seq, durationSec: durationSec)
            try await retrying {
                try await client.putPlaylist(streamId: streamId, text: nextManifest.text)
            }
            manifest = nextManifest
        }
    }

    private func retrying(_ operation: () async throws -> Void) async throws {
        var lastError: Error?

        for attempt in 1...3 {
            do {
                try await operation()
                return
            } catch {
                lastError = error
                guard attempt < 3 else { break }
                let delayMilliseconds = 250 * attempt
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            }
        }

        throw lastError ?? URLError(.unknown)
    }
}

enum HLSUploadError: LocalizedError {
    case mediaBeforeInitialization

    var errorDescription: String? {
        switch self {
        case .mediaBeforeInitialization:
            return "init.mp4より先にmedia segmentを受信しました"
        }
    }
}
