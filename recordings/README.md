# Playing the demo recordings

These are local terminal recordings, not scripts: playback displays captured
output without executing commands or starting the demos. Once the files and
player are on your machine, no internet connection, Docker or Kubernetes is
needed. There is no audio.

## Install the player on macOS

With [Homebrew](https://brew.sh/) installed, run this while connected:

```bash
brew install asciinema
asciinema --version
```

The instructions below were tested with asciinema **3.2.1**, which supports
these asciicast v2 files and their named markers. If an older installation
does not recognize the marker options, run `brew upgrade asciinema`.

If `brew` is not on your shell's `PATH`, follow Homebrew's installation
instructions to enable its shell environment. On Apple Silicon, this is
typically `eval "$(/opt/homebrew/bin/brew shellenv)"`.

## Play a recording

Open Terminal or another terminal emulator, select a readable monospace font,
and make the window at least **120 columns by 36 rows**. Run the following
commands from the repository root, choosing the demo you want:

```bash
asciinema play recordings/live-1/demo.cast
asciinema play recordings/live-2/demo.cast
asciinema play recordings/zarf/demo.cast
```

If your shell is already in this directory, omit the `recordings/` prefix.
Keep the files locally rather than playing a remote URL for an offline talk.

| Demo | Terminal recording | Narration timestamps | Video alternative |
|------|--------------------|----------------------|-------------------|
| LIVE-1: pull-through cache | [demo.cast](live-1/demo.cast) | [chapters.txt](live-1/chapters.txt) | [demo.mp4](live-1/demo.mp4) |
| LIVE-2: signed offline bundle | [demo.cast](live-2/demo.cast) | [chapters.txt](live-2/chapters.txt) | [demo.mp4](live-2/demo.mp4) |
| ADV-01: Zarf lifecycle | [demo.cast](zarf/demo.cast) | [chapters.txt](zarf/chapters.txt) | [demo.mp4](zarf/demo.mp4) |

### Controls and narration

- **Space**: pause or resume.
- **.** (while paused): step forward one event.
- **]** (while paused): skip to the next named marker.
- **Ctrl+C**: stop playback.

To pause automatically at each named marker for narration:

```bash
asciinema play --pause-on-markers recordings/live-1/demo.cast
```

Press Space to continue after each stop. The same option works for the other
two recordings. Without it, playback continues through markers without pausing.

The recordings preserve real timings, including download and initialization
waits. For a quicker rehearsal, either increase the speed or cap idle gaps:

```bash
asciinema play --speed 2 recordings/zarf/demo.cast
asciinema play --idle-time-limit 2 recordings/zarf/demo.cast
```

These options affect playback only; they do not edit the recording.
Use `--speed 1` to explicitly request original speed if your player configuration
sets another default. `--resize` can request the recorded window dimensions,
but not every terminal supports it; manually size the window if text wraps or
is clipped.

## Video fallback

Each demo also includes an H.264 MP4 with embedded chapters. Open it with a
local video player such as QuickTime Player or VLC; asciinema is not required.
For example, from the repository root on macOS:

```bash
open recordings/live-1/demo.mp4
```

Use the chapter timestamps for narration if your video player does not expose
the embedded chapters. Check font size and readability on the actual projector
before the talk.

## MacBook validation

Tested on **2026-11-02**, on an Apple Silicon MacBook running **macOS 27.2
(arm64)**. Installed the missing player with `brew install asciinema`, obtaining
**asciinema 3.2.1**.

- Played all three local casts to completion in a 120x36 pseudo-terminal;
  each player process exited with status 0.
- Played LIVE-1 at original speed, and LIVE-2 and Zarf at 100x for full-file
  smoke checks.
- Played LIVE-1 with `--pause-on-markers`, confirmed all seven automatic pauses,
  and resumed each with Space through successful completion.

These checks validate terminal playback, not visual readability in a GUI
terminal or on a projector, nor MP4 playback on the MacBook.

For capture prerequisites, export recovery and privacy checks, see the
[recording guide](../docs/recordings.md).
