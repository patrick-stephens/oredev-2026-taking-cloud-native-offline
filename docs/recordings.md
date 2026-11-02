# Offline presentation recordings

Capture **LIVE-1**, **LIVE-2** and **ADV-01 (Zarf)** before the talk. Each capture
runs the real connected and air-gapped phases, without narration or interactive
prompts, and produces:

- `demo.mp4`: the primary fallback, H.264/yuv420p with embedded chapters. Copy
  this to the presentation machine and a second device. No demo tools, network,
  registry or Kubernetes cluster are needed for playback.
- `demo.cast`: a local asciinema recording with named markers. It preserves
  terminal text and real timings, including waits; no idle-time compression.
- `chapters.txt`: timestamps for narration and seeking in any video player.
- `chapters.ffmetadata`: the chapter source embedded in the MP4.
- `raw.cast`: the original capture, retained for diagnostics.

These are terminal-only videos: no microphone, presenter camera or desktop
capture. The current three demos are terminal experiences. Use a screen recorder
separately if adding a browser or other GUI demonstration.

## Included fallbacks

| Demo | Full video | Terminal recording | Narration timestamps |
|------|------------|--------------------|----------------------|
| LIVE-1 | [MP4](../recordings/live-1/demo.mp4) | [asciinema](../recordings/live-1/demo.cast) | [Chapters](../recordings/live-1/chapters.txt) |
| LIVE-2 | [MP4](../recordings/live-2/demo.mp4) | [asciinema](../recordings/live-2/demo.cast) | [Chapters](../recordings/live-2/chapters.txt) |
| Zarf | [MP4](../recordings/zarf/demo.mp4) | [asciinema](../recordings/zarf/demo.cast) | [Chapters](../recordings/zarf/chapters.txt) |

Only these reviewed captures and their chapter metadata are versioned. Raw
captures, earlier takes, render intermediates and downloaded setup assets are
not included.

## Capture prerequisites

Use the demos' normal Linux amd64 host, with Docker, Compose, Helm, kind, and
the other requirements in their READMEs. Run the existing provisioner ahead of
time to stage tools and assets:

```bash
./scripts/provision-host.sh --only live-1,live-2,adv-01
```

Separately install these **recording-only** tools on the connected host:

| Tool | Validated version | Purpose |
|------|-------------------|---------|
| [asciinema](https://github.com/asciinema/asciinema/releases/tag/v3.2.1) | 3.2.1 | Headless capture with child exit-status propagation |
| [agg](https://github.com/asciinema/agg/releases/tag/v1.9.0) | 1.9.0 | Render the cast locally to an intermediate GIF |
| [FFmpeg](https://ffmpeg.org/) | 6.1.1 | Encode H.264 MP4 and embed chapters |
| [Node.js](https://nodejs.org/) | 24.22.1 (18+ required) | Generate markers and video chapters |
| jq | Host version | Inspect capture output when diagnosing failures |

Use official release binaries for asciinema/agg matching your OS and
architecture, and put them on `PATH`. FFmpeg must include the `libx264` encoder;
install a monospace font such as DejaVu Sans Mono. Recording tools are deliberately
not part of demo provisioning: playback needs none of them, and individual demos
remain self-contained.

## Capture all three

From the repository root, run these **sequentially**: the live demos both use
port 5000. Allow extra time and disk for initial downloads and GIF rendering.
Each run uses a 120-column, 36-row terminal.

```bash
bash scripts/record-demo.sh live-1
bash scripts/record-demo.sh live-2
bash scripts/record-demo.sh adv-01
```

Each command creates a new timestamped directory under `recordings/`. An
optional second argument chooses another new output directory:

```bash
bash scripts/record-demo.sh live-1 recordings/cache-rehearsal
```

Existing directories are refused rather than overwritten. Recording is local:
there are no uploads, remote streams or external playback assets.

LIVE-1 retains its cache volume; prime output may be warm on later takes. Do not
describe it as cold unless you explicitly reset **only** that demo's volume
using its documented purge command. LIVE-2 includes the tampered-bundle rejection
before deploying the original bundle. Zarf includes packaging, signature and
SBOM checks, isolation, init, deployment and egress evidence; its private init
and deployment logs are not printed.

Successful recordings include normal demo-scoped cleanup. Failed runs return
nonzero and retain `raw.cast`, but do **not** publish a successful cast or video.
Review the raw output with `asciinema play PATH/raw.cast` and inspect the demo's
state before retrying. LIVE-2 runs its existing cleanup trap even on failure;
LIVE-1 and Zarf can leave resources for diagnosis. Use their documented recovery
or cleanup scripts, not broad Docker pruning.

If capture succeeds but rendering fails, keep the finalized cast and retry
only the export:

```bash
bash scripts/record-demo.sh --export recordings/cache-rehearsal
```

Failed exports retain a private `.export.*` directory for diagnosis; retries use
a new one. After reviewing it, remove only that failed export's intermediate
files. Successful exports remove their intermediate GIF automatically.

## Playback and narration

1. Open `demo.mp4` in a local player such as VLC. Confirm readable text, duration
   and chapter navigation on the actual projector before the session.
2. Play the whole video as the default fallback. Use Space to pause for narration;
   use the embedded chapters or `chapters.txt` to find the next important beat.
   The movie does **not** auto-pause: uninterrupted playback remains available.
3. Alternatively run `asciinema play PATH/demo.cast` in a terminal at least
   120x36, and press Space to pause/resume. Marker-aware asciinema players can
   also navigate the embedded named markers.

Recommended narration stops are the deliberate upstream failure and cache hit
in LIVE-1; tamper rejection, verified import and PostgreSQL deployment in LIVE-2;
and signature verification, offline init, admitted-image rewrite and final
egress evidence in Zarf. Markers are generated from actual phase banners and
proof lines, not hard-coded wall-clock estimates.

Timing is intentionally real-time in both formats. Long download or init waits
are not silently edited out. To speed up delivery, pre-stage assets, record a
fresh take, or change playback speed in the player. There is a three-second end
hold after the last output. Capture sets `DEMO_RECORDING=1`, which also holds
each proof screen for three seconds before the next phase clears it; normal
live demo pacing is unchanged.

## Privacy and validation

New output directories/files are owner-only. Recordings are gitignored except
for the reviewed fallback files listed above.
**Review every recording before sharing it**: terminal output may contain
hostnames, local paths, digests, credentials or other sensitive material.
Keyboard input and extra environment variables are not requested for capture.
Do not enable shell tracing or print private Zarf `.state/` logs.

Check deliverables without running a demo again:

```bash
node --test scripts/recording-chapters.test.mjs
shellcheck scripts/record-demo.sh
ffprobe -v error -show_entries format=duration:stream=codec_name,width,height,pix_fmt \
  -show_chapters -of json recordings/cache-rehearsal/demo.mp4
```

Rehearse offline playback on the presentation machine. These scripts verify
real demo exit status and completion checkpoints, but a successful encoding is
not a substitute for watching the result on your talk setup.

### Capture validation on 2026-11-02

All three full demos completed successfully on Linux amd64 with Docker 29.9.2,
using the recording tool versions above. Generated local takes:

| Demo | Duration | Chapters | MP4 size |
|------|----------|----------|----------|
| LIVE-1 | 23.7 seconds | 7 | 1.1 MiB |
| LIVE-2, including tamper rejection | 79.0 seconds | 9 | 1.1 MiB |
| Zarf lifecycle, including fresh offline init | 215.4 seconds | 12 | 8.8 MiB |

These are complete real-time terminal videos, not narrated screen recordings.
LIVE-1 used a retained warm cache; tools and infrastructure images were staged.
Each MP4 decoded successfully with FFmpeg, with 1470x1036 H.264/yuv420p output,
matching cast markers and chapter endpoints within 0.1 seconds of video duration.
Representative proof frames were visually checked. Demo containers/clusters
were cleaned up; unrelated Docker builders remained running.
