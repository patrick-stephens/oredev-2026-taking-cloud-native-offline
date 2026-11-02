#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: scripts/record-demo.sh {live-1|live-2|adv-01} [OUTPUT_DIRECTORY]
       scripts/record-demo.sh --export RECORDING_DIRECTORY

Runs the real demo unattended, records a local asciicast, then exports an MP4
with chapters. No uploads. Existing output directories are never overwritten.
Default output: recordings/DEMO-UTC_TIMESTAMP

Requires asciinema 3.2+, agg 1.9+, Node.js 18+, jq, ffmpeg and the demo's tools.
--export retries video export without re-running a successfully captured demo.
EOF
}

run_demo() {
    export DEMO_AUTO_ADVANCE=1 DEMO_RECORDING=1 TERM=xterm-256color
    case "$1" in
        live-1)
            cd "$ROOT/live-demos/1-pull-through-cache-zot"
            bash scripts/start-cache.sh
            bash scripts/prime-cache.sh
            bash scripts/verify-cache.sh
            bash scripts/stop-cache.sh
            ;;
        live-2)
            cd "$ROOT/live-demos/2-offline-bundle-cosign"
            bash run-demo.sh --tamper
            ;;
        adv-01)
            cd "$ROOT/advanced-demos/zarf-package-lifecycle"
            bash scripts/run-demo.sh
            bash scripts/cleanup.sh
            ;;
        *) die "Unknown demo: $1" ;;
    esac
    printf '\nRECORDING COMPLETE: %s succeeded, including demo-scoped cleanup.\n' "$1"
    sleep 3
}

export_video() {
    local directory=$1 work
    [[ -s "$directory/demo.cast" && -s "$directory/chapters.ffmetadata" ]] ||
        die "No finalized successful capture in $directory."
    [[ ! -e "$directory/demo.mp4" ]] || die "demo.mp4 already exists; choose a fresh directory."
    work="$(mktemp -d "$directory/.export.XXXXXX")"
    # Keep real timings: agg otherwise shortens idle periods to five seconds,
    # which would put video chapters on a different timeline from the cast.
    agg --quiet --idle-time-limit 86400 --last-frame-duration 3 --fps-cap 15 \
        --font-size 20 --theme asciinema --no-loop \
        "$directory/demo.cast" "$work/render.gif"
    ffmpeg -nostdin -hide_banner -loglevel warning -n \
        -i "$work/render.gif" -f ffmetadata -i "$directory/chapters.ffmetadata" \
        -map 0:v:0 -map_metadata 1 -map_chapters 1 \
        -vf 'pad=ceil(iw/2)*2:ceil(ih/2)*2' -r 15 \
        -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -movflags +faststart \
        "$work/demo.mp4"
    ln -T -- "$work/demo.mp4" "$directory/demo.mp4"
    rm -- "$work/demo.mp4" "$work/render.gif"
    rmdir -- "$work"
    printf 'Offline fallback ready: %s/demo.mp4\n' "$directory"
}

if [[ ${1:-} == --run ]]; then
    [[ $# == 2 ]] || die "Internal --run requires a demo ID."
    run_demo "$2"
    exit
fi

[[ ${1:-} != -h && ${1:-} != --help ]] || { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
for tool in asciinema agg node jq ffmpeg; do
    command -v "$tool" >/dev/null || die "Missing recording tool: $tool (see docs/recordings.md)."
done

if [[ "$1" == --export ]]; then
    [[ $# == 2 && -d "$2" ]] || die "--export needs an existing recording directory."
    export_video "$(cd -- "$2" && pwd)"
    exit
fi
case "$1" in
    live-1|live-2|adv-01) demo=$1 ;;
    *) usage >&2; die "Unknown demo: $1" ;;
esac

directory="${2:-$ROOT/recordings/$demo-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p -- "$(dirname -- "$directory")"
mkdir -- "$directory" || die "Use a new output directory with an existing parent: $directory"
directory="$(cd -- "$directory" && pwd)"
printf -v command 'bash %q --run %q' "$ROOT/scripts/record-demo.sh" "$demo"
# An explicit shell makes %q quoting independent of the user's login shell.
if SHELL=/bin/bash asciinema record --headless --return --output-format asciicast-v2 \
    --capture-env SHELL \
    --window-size 120x36 --title "$demo - Taking cloud-native offline" \
    --command "$command" "$directory/raw.cast"; then
    node "$ROOT/scripts/recording-chapters.mjs" "$directory"
else
    status=$?
    printf 'ERROR: %s failed (exit %s). Diagnostic capture: %s/raw.cast\n' \
        "$demo" "$status" "$directory" >&2
    printf 'No successful fallback was published. Inspect demo state before retrying.\n' >&2
    exit "$status"
fi
export_video "$directory"
