import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from server.server import create_server


class LocalHLSServerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        repository_root = Path(__file__).resolve().parents[2]
        self.server = create_server(
            host="127.0.0.1",
            port=0,
            data_directory=Path(self.temporary_directory.name),
            static_directory=repository_root / "server" / "static",
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary_directory.cleanup()

    def test_health_and_viewer_are_available(self) -> None:
        with urllib.request.urlopen(f"{self.base_url}/health") as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(json.load(response), {"ok": True})

        with urllib.request.urlopen(self.base_url) as response:
            self.assertEqual(response.status, 200)
            self.assertIn(b"iOSDC HLS Viewer", response.read())

    def test_uploaded_objects_are_served_with_hls_headers(self) -> None:
        data = b"0123456789"
        self.put("/streams/stream-1/init.mp4", data, "video/mp4")

        request = urllib.request.Request(
            f"{self.base_url}/streams/stream-1/init.mp4",
            headers={"Range": "bytes=2-5"},
        )
        with urllib.request.urlopen(request) as response:
            self.assertEqual(response.status, 206)
            self.assertEqual(response.headers["Content-Type"], "video/mp4")
            self.assertEqual(response.headers["Content-Range"], "bytes 2-5/10")
            self.assertEqual(response.read(), b"2345")

    def test_playlist_can_be_replaced_and_is_listed(self) -> None:
        path = "/streams/stream-2/playlist.m3u8"
        first = b"#EXTM3U\n#EXTINF:2.000,\nseg/000001.m4s\n"
        final = first + b"#EXTINF:2.000,\nseg/000002.m4s\n#EXT-X-ENDLIST\n"
        self.put(path, first, "application/vnd.apple.mpegurl")
        self.put(path, final, "application/vnd.apple.mpegurl")

        with urllib.request.urlopen(f"{self.base_url}{path}") as response:
            self.assertEqual(response.headers["Cache-Control"], "no-cache, no-store, must-revalidate")
            self.assertEqual(response.read(), final)

        with urllib.request.urlopen(f"{self.base_url}/api/streams") as response:
            streams = json.load(response)["streams"]

        self.assertEqual(len(streams), 1)
        self.assertEqual(streams[0]["streamId"], "stream-2")
        self.assertEqual(streams[0]["segmentCount"], 2)
        self.assertTrue(streams[0]["isFinished"])

    def test_invalid_and_oversized_uploads_are_rejected(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as traversal_error:
            self.put("/streams/stream-1/seg/%2e%2e/init.mp4", b"data", "video/mp4")
        self.assertEqual(traversal_error.exception.code, 404)

        self.server.max_body_bytes = 3
        with self.assertRaises(urllib.error.HTTPError) as size_error:
            self.put("/streams/stream-1/init.mp4", b"data", "video/mp4")
        self.assertEqual(size_error.exception.code, 413)

    def put(self, path: str, data: bytes, content_type: str) -> None:
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=data,
            method="PUT",
            headers={"Content-Type": content_type},
        )
        with urllib.request.urlopen(request) as response:
            self.assertEqual(response.status, 204)


if __name__ == "__main__":
    unittest.main()
