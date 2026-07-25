import Foundation

struct LocalHLSManifest: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let seq: Int
        let durationSec: Double

        var uri: String {
            "seg/\(LocalHLSManifest.paddedSequence(seq)).m4s"
        }
    }

    let targetDurationSec: Int
    private var segmentsBySeq: [Int: Segment] = [:]
    private var isFinished = false

    var segmentCount: Int {
        segmentsBySeq.count
    }

    var text: String {
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

    init(targetDurationSec: Int) {
        self.targetDurationSec = max(1, targetDurationSec)
    }

    mutating func addSegment(seq: Int, durationSec: Double) {
        guard seq > 0 else { return }
        segmentsBySeq[seq] = Segment(seq: seq, durationSec: durationSec)
    }

    mutating func finish() {
        isFinished = true
    }

    static func paddedSequence(_ seq: Int) -> String {
        String(format: "%06d", seq)
    }

    private var orderedSegments: [Segment] {
        segmentsBySeq.values.sorted { $0.seq < $1.seq }
    }
}
