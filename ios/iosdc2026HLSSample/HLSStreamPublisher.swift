import Foundation

/// RecorderからPublisherへ渡す、HLSを構成する最小単位。
enum HLSFragment: Sendable {
    /// 再生開始時に1度だけ必要な `init.mp4`。
    case initialization(Data)
    /// 約2秒ごとに生成される `.m4s`。durationはplaylistのEXTINFに使う。
    case media(sequence: Int, data: Data, duration: Double)
}

/// UIが配信状況を表示するための、Publisherの読み取り専用スナップショット。
struct HLSStreamSnapshot: Equatable, Sendable {
    let streamId: String
    let viewerURL: URL
    let playlistURL: URL
    let playlistText: String
    let segmentCount: Int
    let errorMessage: String?
}

/// HLS fragmentを「Viewerから参照してよい順番」でHTTP公開するactor。
///
/// 公開順は次のとおり。
///
/// 1. `init.mp4` をPUTする
/// 2. `.m4s` をPUTする
/// 3. PUTに成功したsegmentだけを `playlist.m3u8` へ追加する
/// 4. 入力stream完了後に `#EXT-X-ENDLIST` を付ける
///
/// actorでmanifestと公開済みsequenceを直列化し、並行uploadによる順序の逆転を防ぐ。
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

    /// Recorderが生成するfragment streamを、完了または失敗まで消費する。
    func publish(_ fragments: AsyncThrowingStream<HLSFragment, Error>) async {
        do {
            for try await fragment in fragments {
                // 最初の失敗をsnapshotへ残し、それ以降は新しいファイルを公開しない。
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

        // ENDLISTは「これ以上segmentが増えない」という宣言である。
        // Recorderのstreamが正常終了し、最低限再生できるファイルが揃った後だけ公開する。
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

    /// actorが所有する現在の配信状態を、UIへ安全に渡せる値へ変換する。
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
            // EXT-X-MAPが参照する前提ファイルなので、media segmentより先に保存する。
            guard !didUploadInitSegment else { return }
            try await retrying {
                try await client.putInitSegment(streamId: streamId, data: data)
            }
            didUploadInitSegment = true

        case let .media(sequence, data, duration):
            guard didUploadInitSegment else {
                throw HLSStreamPublisherError.mediaBeforeInitialization
            }

            // Viewerが404を引かないよう、segment本体のPUT成功を先に確定する。
            try await retrying {
                try await client.putMediaSegment(streamId: streamId, seq: sequence, data: data)
            }

            // manifestは候補をコピーして作り、playlistのPUT成功後にだけローカル状態へ反映する。
            // 失敗したsegmentがplaylistに残らない、簡単なtransaction境界となる。
            var nextManifest = manifest
            nextManifest.addSegment(seq: sequence, durationSec: duration)
            try await retrying {
                try await client.putPlaylist(streamId: streamId, text: nextManifest.text)
            }
            manifest = nextManifest
        }
    }

    /// 一時的な通信失敗を想定し、同じPUTを最大3回まで再試行する。
    /// URLと内容が同じPUTなので、再試行しても保存結果は重複しない。
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

/// fragmentの順序がHLSの前提を満たさない場合のエラー。
enum HLSStreamPublisherError: LocalizedError {
    case mediaBeforeInitialization

    var errorDescription: String? {
        switch self {
        case .mediaBeforeInitialization:
            return "init.mp4より先にmedia segmentを受信しました"
        }
    }
}
