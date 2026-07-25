import Foundation
import Testing
@testable import iosdc2026HLSSample

struct LocalHLSManifestTests {
    @Test func initialPlaylistContainsRequiredTags() {
        let manifest = LocalHLSManifest(targetDurationSec: 2)

        #expect(manifest.text.contains("#EXTM3U"))
        #expect(manifest.text.contains("#EXT-X-VERSION:7"))
        #expect(manifest.text.contains("#EXT-X-TARGETDURATION:2"))
        #expect(manifest.text.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        #expect(manifest.text.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        #expect(manifest.text.contains("#EXT-X-MEDIA-SEQUENCE:1"))
    }

    @Test func segmentUsesPaddedRelativePath() {
        var manifest = LocalHLSManifest(targetDurationSec: 2)

        manifest.addSegment(seq: 1, durationSec: 2.0)

        #expect(manifest.text.contains("#EXTINF:2.000,\nseg/000001.m4s"))
    }

    @Test func duplicateSeqIsNotWrittenTwice() {
        var manifest = LocalHLSManifest(targetDurationSec: 2)

        manifest.addSegment(seq: 1, durationSec: 2.0)
        manifest.addSegment(seq: 1, durationSec: 2.0)

        #expect(manifest.segmentCount == 1)
        #expect(manifest.text.components(separatedBy: "seg/000001.m4s").count == 2)
    }

    @Test func segmentsAreSortedBySequence() {
        var manifest = LocalHLSManifest(targetDurationSec: 2)

        manifest.addSegment(seq: 2, durationSec: 2.0)
        manifest.addSegment(seq: 1, durationSec: 2.0)
        manifest.addSegment(seq: 3, durationSec: 2.0)

        let text = manifest.text
        let first = text.range(of: "seg/000001.m4s")
        let second = text.range(of: "seg/000002.m4s")
        let third = text.range(of: "seg/000003.m4s")

        #expect(first != nil)
        #expect(second != nil)
        #expect(third != nil)
        #expect(first!.lowerBound < second!.lowerBound)
        #expect(second!.lowerBound < third!.lowerBound)
    }

    @Test func endlistIsWrittenOnceAtTheEnd() {
        var manifest = LocalHLSManifest(targetDurationSec: 2)

        manifest.addSegment(seq: 1, durationSec: 2.0)
        manifest.finish()
        manifest.finish()

        let text = manifest.text
        #expect(text.components(separatedBy: "#EXT-X-ENDLIST").count == 2)
        #expect(text.hasSuffix("#EXT-X-ENDLIST\n"))
    }
}
