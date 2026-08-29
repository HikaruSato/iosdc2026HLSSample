import Foundation

enum HLSFragment: Sendable {
    case initialization(Data)
    case media(sequence: Int, data: Data, duration: Double)
}

struct HLSStreamSnapshot: Equatable, Sendable {
    let streamId: String
    let viewerURL: URL
    let playlistURL: URL
    let playlistText: String
    let segmentCount: Int
    let errorMessage: String?
}

actor HLSStreamPublisher {
    private let client: any HLSClient
    private let streamId: String
    private var manifest: HLSManifest

    private var didUploadInitSegment = false
    private var errorMessage: String?

    init(
        client: any HLSClient,
        streamId: String,
        targetDurationSec: Int
    ) {
        self.client = client
        self.streamId = streamId
        manifest = HLSManifest(targetDurationSec: targetDurationSec)
    }

    func publish(_ fragments: AsyncThrowingStream<HLSFragment, Error>) async {
        do {
            for try await fragment in fragments {
                guard errorMessage == nil else { continue }

                do {
                    try await publish(fragment)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            if errorMessage == nil {
                errorMessage = error.localizedDescription
            }
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func snapshot() -> HLSStreamSnapshot {
        HLSStreamSnapshot(
            streamId: streamId,
            viewerURL: client.viewerURL,
            playlistURL: client.playlistURL(streamId: streamId),
            playlistText: manifest.text,
            segmentCount: manifest.segmentCount,
            errorMessage: errorMessage
        )
    }

    private func publish(_ fragment: HLSFragment) async throws {
        switch fragment {
        case let .initialization(data):
            guard !didUploadInitSegment else { return }
            try await retrying {
                try await client.putInitSegment(streamId: streamId, data: data)
            }
            didUploadInitSegment = true

        case let .media(sequence, data, duration):
            guard didUploadInitSegment else {
                throw HLSStreamPublisherError.mediaBeforeInitialization
            }

            try await retrying {
                try await client.putMediaSegment(streamId: streamId, seq: sequence, data: data)
            }

            var nextManifest = manifest
            nextManifest.addSegment(seq: sequence, durationSec: duration)
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
                try? await Task.sleep(for: .milliseconds(250 * attempt))
            }
        }

        throw lastError ?? URLError(.unknown)
    }
}

enum HLSStreamPublisherError: LocalizedError {
    case mediaBeforeInitialization

    var errorDescription: String? {
        switch self {
        case .mediaBeforeInitialization:
            return "init.mp4より先にmedia segmentを受信しました"
        }
    }
}
