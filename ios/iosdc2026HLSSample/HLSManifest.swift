import Foundation

/// 生成済みsegmentから、HLSのMedia Playlist本文を組み立てる値型。
///
/// 通信処理を持たないため、タグの出力や並び順を単体テストできる。
struct HLSManifest: Equatable, Sendable {
    /// playlistに公開する1つのmedia segment。
    struct Segment: Equatable, Sendable {
        let seq: Int
        let durationSec: Double

        /// PublisherとHTTPClientが共有する、ゼロ埋めしたsegmentの相対パス。
        var uri: String {
            "seg/\(HLSManifest.paddedSequence(seq)).m4s"
        }
    }

    let targetDurationSec: Int
    private var segmentsBySeq: [Int: Segment] = [:]
    private var isFinished = false

    var segmentCount: Int {
        segmentsBySeq.count
    }

    /// Viewerが繰り返しGETする `playlist.m3u8` の全文。
    ///
    /// - `EXT-X-MAP`: 再生準備に使う `init.mp4`
    /// - `EXTINF`: 各segmentの実測duration
    /// - `EXT-X-ENDLIST`: 配信終了後だけ追加する終端マーカー
    var text: String {
        // EVENT playlistは過去のsegmentを保持したまま、末尾へ新しいsegmentを追加していく。
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDurationSec)",
            "#EXT-X-PLAYLIST-TYPE:EVENT",
            "#EXT-X-MAP:URI=\"init.mp4\"",
            "#EXT-X-MEDIA-SEQUENCE:1",
            ""
        ]

        for segment in orderedSegments {
            lines.append("#EXTINF:\(String(format: "%.3f", segment.durationSec)),")
            lines.append(segment.uri)
        }

        if isFinished {
            lines.append("#EXT-X-ENDLIST")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// TARGETDURATIONはHLS上1秒以上必要なため、入力値を下限1に丸める。
    init(targetDurationSec: Int) {
        self.targetDurationSec = max(1, targetDurationSec)
    }

    /// 公開済みsegmentを追加する。同じsequenceは上書きし、重複行を作らない。
    mutating func addSegment(seq: Int, durationSec: Double) {
        guard seq > 0 else { return }
        segmentsBySeq[seq] = Segment(seq: seq, durationSec: durationSec)
    }

    /// playlistの末尾へ `EXT-X-ENDLIST` を追加する状態にする。
    mutating func finish() {
        isFinished = true
    }

    /// ファイル一覧を名前順でもsequence順に読めるよう、6桁でゼロ埋めする。
    static func paddedSequence(_ seq: Int) -> String {
        String(format: "%06d", seq)
    }

    /// Dictionaryの挿入順に依存せず、playlistには必ずsequence順で出力する。
    private var orderedSegments: [Segment] {
        segmentsBySeq.values.sorted { $0.seq < $1.seq }
    }
}
