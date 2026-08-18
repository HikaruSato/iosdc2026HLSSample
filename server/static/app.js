const player = document.querySelector("#player");
const emptyState = document.querySelector("#empty-state");
const status = document.querySelector("#status");
const streamId = document.querySelector("#stream-id");
const segmentCount = document.querySelector("#segment-count");
const playlistURL = document.querySelector("#playlist-url");

let activeStreamId = null;
let hls = null;

function setStatus(kind, text) {
  status.className = `status ${kind}`;
  status.querySelector("span").textContent = text;
}

function destroyPlayer() {
  if (hls) {
    hls.destroy();
    hls = null;
  }
  player.pause();
  player.removeAttribute("src");
  player.load();
}

function loadStream(stream) {
  activeStreamId = stream.streamId;
  emptyState.classList.add("hidden");
  const sourceURL = `${stream.playlistURL}?stream=${encodeURIComponent(stream.streamId)}`;

  if (player.canPlayType("application/vnd.apple.mpegurl")) {
    player.src = sourceURL;
    player.play().catch(() => {});
    return;
  }

  if (window.Hls && window.Hls.isSupported()) {
    hls = new window.Hls({
      liveSyncDurationCount: 2,
      maxLiveSyncPlaybackRate: 1.2,
    });
    hls.loadSource(sourceURL);
    hls.attachMedia(player);
    hls.on(window.Hls.Events.MANIFEST_PARSED, () => {
      player.play().catch(() => {});
    });
    hls.on(window.Hls.Events.ERROR, (_, data) => {
      if (!data.fatal) return;
      if (data.type === window.Hls.ErrorTypes.NETWORK_ERROR) {
        hls.startLoad();
      } else if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR) {
        hls.recoverMediaError();
      } else {
        setStatus("error", "PLAYBACK ERROR");
        hls.destroy();
        hls = null;
      }
    });
    return;
  }

  setStatus("error", "HLS UNSUPPORTED");
}

function render(stream) {
  streamId.textContent = stream.streamId;
  segmentCount.textContent = String(stream.segmentCount);
  playlistURL.textContent = stream.playlistURL;
  setStatus(stream.isFinished ? "ended" : "live", stream.isFinished ? "ENDED" : "LIVE");

  if (stream.streamId !== activeStreamId) {
    destroyPlayer();
    loadStream(stream);
  }
}

async function pollLatestStream() {
  try {
    const response = await fetch("/api/streams", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const payload = await response.json();
    const latest = payload.streams[0];

    if (latest) {
      render(latest);
    } else {
      setStatus("waiting", "WAITING");
    }
  } catch (error) {
    setStatus("error", "SERVER ERROR");
    console.error(error);
  }
}

pollLatestStream();
window.setInterval(pollLatestStream, 1000);
