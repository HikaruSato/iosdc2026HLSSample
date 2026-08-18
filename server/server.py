#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import mimetypes
import os
import re
import socket
import tempfile
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit


DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8080
DEFAULT_MAX_BODY_BYTES = 32 * 1024 * 1024
STREAM_OBJECT_PATTERN = re.compile(
    r"^/streams/(?P<stream_id>[A-Za-z0-9_-]{1,128})/"
    r"(?P<object_path>init\.mp4|playlist\.m3u8|seg/[0-9]{6}\.m4s)$"
)

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".m3u8": "application/vnd.apple.mpegurl",
    ".mp4": "video/mp4",
    ".m4s": "video/mp4",
    ".txt": "text/plain; charset=utf-8",
}


class LocalHLSServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        server_address: tuple[str, int],
        data_directory: Path,
        static_directory: Path,
        max_body_bytes: int = DEFAULT_MAX_BODY_BYTES,
    ) -> None:
        self.data_directory = data_directory.resolve()
        self.static_directory = static_directory.resolve()
        self.max_body_bytes = max_body_bytes
        self.data_directory.mkdir(parents=True, exist_ok=True)
        super().__init__(server_address, LocalHLSRequestHandler)


class LocalHLSRequestHandler(BaseHTTPRequestHandler):
    server: LocalHLSServer
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        self._handle_read(head_only=False)

    def do_HEAD(self) -> None:
        self._handle_read(head_only=True)

    def do_PUT(self) -> None:
        path = self._request_path()
        object_match = STREAM_OBJECT_PATTERN.fullmatch(path)
        if object_match is None:
            self._send_json(404, {"error": "Unsupported upload path"})
            return

        content_length_text = self.headers.get("Content-Length")
        if content_length_text is None:
            self._send_json(411, {"error": "Content-Length is required"})
            return

        try:
            content_length = int(content_length_text)
        except ValueError:
            self._send_json(400, {"error": "Invalid Content-Length"})
            return

        if content_length <= 0:
            self._send_json(400, {"error": "Upload body must not be empty"})
            return
        if content_length > self.server.max_body_bytes:
            self._send_json(413, {"error": "Upload body is too large"})
            return

        destination = self._object_file_path(object_match)
        destination.parent.mkdir(parents=True, exist_ok=True)

        temporary_path: Path | None = None
        try:
            file_descriptor, temporary_name = tempfile.mkstemp(
                prefix=f".{destination.name}.",
                dir=destination.parent,
            )
            temporary_path = Path(temporary_name)
            with os.fdopen(file_descriptor, "wb") as output:
                remaining = content_length
                while remaining > 0:
                    chunk = self.rfile.read(min(64 * 1024, remaining))
                    if not chunk:
                        raise ValueError("Upload body ended before Content-Length")
                    output.write(chunk)
                    remaining -= len(chunk)
                output.flush()
                os.fsync(output.fileno())

            os.replace(temporary_path, destination)
            temporary_path = None
        except ValueError as error:
            self.close_connection = True
            self._send_json(400, {"error": str(error)})
            return
        except OSError as error:
            self._send_json(500, {"error": f"Failed to store object: {error}"})
            return
        finally:
            if temporary_path is not None:
                temporary_path.unlink(missing_ok=True)

        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _handle_read(self, head_only: bool) -> None:
        path = self._request_path()

        if path == "/health":
            self._send_json(200, {"ok": True}, head_only=head_only)
            return

        if path == "/api/streams":
            self._send_json(
                200,
                {"streams": self._stream_summaries()},
                head_only=head_only,
                cache_control="no-store",
            )
            return

        if path == "/":
            self._serve_file(
                self.server.static_directory / "index.html",
                head_only=head_only,
                cache_control="no-store",
            )
            return

        if path.startswith("/static/"):
            relative_path = path.removeprefix("/static/")
            static_file = self._safe_child(self.server.static_directory, relative_path)
            if static_file is None:
                self._send_json(404, {"error": "Not found"}, head_only=head_only)
                return
            self._serve_file(
                static_file,
                head_only=head_only,
                cache_control="public, max-age=86400",
            )
            return

        object_match = STREAM_OBJECT_PATTERN.fullmatch(path)
        if object_match is not None:
            object_path = object_match.group("object_path")
            cache_control = (
                "no-cache, no-store, must-revalidate"
                if object_path == "playlist.m3u8"
                else "public, max-age=31536000, immutable"
            )
            self._serve_file(
                self._object_file_path(object_match),
                head_only=head_only,
                cache_control=cache_control,
            )
            return

        self._send_json(404, {"error": "Not found"}, head_only=head_only)

    def _serve_file(self, path: Path, head_only: bool, cache_control: str) -> None:
        if not path.is_file():
            self._send_json(404, {"error": "Not found"}, head_only=head_only)
            return

        file_size = path.stat().st_size
        byte_range = self._parse_range(file_size)
        if byte_range is False:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{file_size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if byte_range is None:
            status_code = 200
            start = 0
            end = max(0, file_size - 1)
        else:
            status_code = 206
            start, end = byte_range

        content_length = 0 if file_size == 0 else end - start + 1
        self.send_response(status_code)
        self.send_header("Content-Type", self._content_type(path))
        self.send_header("Content-Length", str(content_length))
        self.send_header("Cache-Control", cache_control)
        self.send_header("Accept-Ranges", "bytes")
        if status_code == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
        self.end_headers()

        if head_only or content_length == 0:
            return

        try:
            with path.open("rb") as input_file:
                input_file.seek(start)
                remaining = content_length
                while remaining > 0:
                    chunk = input_file.read(min(64 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _parse_range(self, file_size: int) -> tuple[int, int] | None | bool:
        range_header = self.headers.get("Range")
        if range_header is None:
            return None

        match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header.strip())
        if match is None or file_size == 0:
            return False

        start_text, end_text = match.groups()
        if not start_text and not end_text:
            return False

        if start_text:
            start = int(start_text)
            end = int(end_text) if end_text else file_size - 1
        else:
            suffix_length = int(end_text)
            if suffix_length <= 0:
                return False
            start = max(0, file_size - suffix_length)
            end = file_size - 1

        if start >= file_size or start > end:
            return False
        return start, min(end, file_size - 1)

    def _stream_summaries(self) -> list[dict[str, Any]]:
        streams_directory = self.server.data_directory / "streams"
        if not streams_directory.is_dir():
            return []

        summaries: list[dict[str, Any]] = []
        for stream_directory in streams_directory.iterdir():
            if not stream_directory.is_dir():
                continue
            if re.fullmatch(r"[A-Za-z0-9_-]{1,128}", stream_directory.name) is None:
                continue

            playlist_path = stream_directory / "playlist.m3u8"
            if not playlist_path.is_file():
                continue

            try:
                playlist_text = playlist_path.read_text(encoding="utf-8")
                modified_at = playlist_path.stat().st_mtime
            except (OSError, UnicodeError):
                continue

            summaries.append(
                {
                    "streamId": stream_directory.name,
                    "playlistURL": f"/streams/{stream_directory.name}/playlist.m3u8",
                    "updatedAt": datetime.fromtimestamp(
                        modified_at,
                        tz=timezone.utc,
                    ).isoformat().replace("+00:00", "Z"),
                    "segmentCount": sum(
                        1 for line in playlist_text.splitlines() if line.startswith("#EXTINF:")
                    ),
                    "isFinished": "#EXT-X-ENDLIST" in playlist_text.splitlines(),
                    "modifiedAt": modified_at,
                }
            )

        summaries.sort(key=lambda item: item["modifiedAt"], reverse=True)
        for summary in summaries:
            summary.pop("modifiedAt", None)
        return summaries

    def _object_file_path(self, object_match: re.Match[str]) -> Path:
        return (
            self.server.data_directory
            / "streams"
            / object_match.group("stream_id")
            / object_match.group("object_path")
        )

    def _safe_child(self, root: Path, relative_path: str) -> Path | None:
        candidate = (root / relative_path).resolve()
        try:
            candidate.relative_to(root)
        except ValueError:
            return None
        return candidate

    def _request_path(self) -> str:
        return unquote(urlsplit(self.path).path)

    def _content_type(self, path: Path) -> str:
        return CONTENT_TYPES.get(
            path.suffix.lower(),
            mimetypes.guess_type(path.name)[0] or "application/octet-stream",
        )

    def _send_json(
        self,
        status_code: int,
        payload: dict[str, Any],
        head_only: bool = False,
        cache_control: str = "no-store",
    ) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache_control)
        self.end_headers()
        if not head_only:
            self.wfile.write(body)


def create_server(
    host: str = DEFAULT_HOST,
    port: int = DEFAULT_PORT,
    data_directory: Path | None = None,
    static_directory: Path | None = None,
    max_body_bytes: int = DEFAULT_MAX_BODY_BYTES,
) -> LocalHLSServer:
    module_directory = Path(__file__).resolve().parent
    return LocalHLSServer(
        (host, port),
        data_directory=data_directory or module_directory / "data",
        static_directory=static_directory or module_directory / "static",
        max_body_bytes=max_body_bytes,
    )


def local_ip_address() -> str | None:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp_socket:
            udp_socket.connect(("192.0.2.1", 80))
            return str(udp_socket.getsockname()[0])
    except OSError:
        return None


def main() -> None:
    parser = argparse.ArgumentParser(description="Local HLS object server")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", default=DEFAULT_PORT, type=int)
    parser.add_argument("--data-dir", type=Path)
    args = parser.parse_args()

    http_server = create_server(
        host=args.host,
        port=args.port,
        data_directory=args.data_dir,
    )
    actual_port = http_server.server_address[1]
    print(f"Viewer: http://localhost:{actual_port}")
    if address := local_ip_address():
        print(f"iPhone server URL: http://{address}:{actual_port}")
    print("Press Control-C to stop")

    try:
        http_server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping server")
    finally:
        http_server.server_close()


if __name__ == "__main__":
    main()
