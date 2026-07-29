#!/usr/bin/env bash
# Verifies that the ducking graph shape the compiler emits both parses and
# actually ducks.
#
# A unit test can prove the compiler writes `sidechaincompress` with the right
# parameters. Only ffmpeg can prove the resulting graph is legal — in
# particular that the key track is split so it stays audible, which is the
# mistake that makes the voice vanish from the export — and that the music
# measurably drops while the voice plays.
#
# Requires ffmpeg on PATH. Run from the repository root:
#     ./tool/verify_ducking.sh

set -euo pipefail

command -v ffmpeg >/dev/null || { echo "ffmpeg not found on PATH"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "ffmpeg: $(ffmpeg -version | head -1)"
echo

# ── 0. The filter has to exist in this build ────────────────────────────
ffmpeg -hide_banner -filters 2>/dev/null | awk '$2=="sidechaincompress"' | grep -q . \
    || { echo "FAIL: this ffmpeg has no sidechaincompress"; exit 1; }
echo "== sidechaincompress present =="
echo

# Music: a steady tone. Voice: the same idea, audible only between 1s and 2s.
ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=440:duration=4" \
    -c:a pcm_s16le music.wav
ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=200:duration=4" \
    -af "volume=enable='between(t,1,2)':volume=1,volume=enable='not(between(t,1,2))':volume=0" \
    -c:a pcm_s16le voice.wav

# ── 1. The full graph shape, exactly as TimelineCompiler emits it ───────
# asplit gives the key track one branch per ducker plus one that stays in the
# mix; every branch must be consumed or ffmpeg refuses the graph.
echo "== the emitted graph shape parses =="
ffmpeg -hide_banner -loglevel error -i music.wav -i voice.wav -filter_complex \
"[1:a]asplit=2[k0][kmix];\
[0:a][k0]sidechaincompress=threshold=0.05:ratio=8:attack=20:release=300:makeup=1[duck];\
[duck][kmix]amix=inputs=2:duration=longest:normalize=0[aout]" \
    -map "[aout]" -c:a pcm_s16le mixed.wav
echo "  accepted, and the key track is still in the mix"
echo

# ── 2. It has to actually duck ──────────────────────────────────────────
echo "== the music measurably steps aside =="
ffmpeg -hide_banner -loglevel error -i music.wav -i voice.wav -filter_complex \
"[0:a][1:a]sidechaincompress=threshold=0.05:ratio=8:attack=20:release=300:makeup=1[duck]" \
    -map "[duck]" -c:a pcm_s16le ducked.wav

rms() {
    ffmpeg -hide_banner -i ducked.wav \
        -af "atrim=$1,astats=measure_overall=RMS_level:measure_perchannel=none" \
        -f null - 2>&1 | grep -m1 "RMS level" | sed 's/.*RMS level dB: //'
}

BEFORE="$(rms 0:1)"
DURING="$(rms 1:2)"
AFTER="$(rms 2.5:3.5)"

printf "  before  %8s dB\n" "$BEFORE"
printf "  during  %8s dB\n" "$DURING"
printf "  after   %8s dB\n" "$AFTER"

awk -v b="$BEFORE" -v d="$DURING" -v a="$AFTER" 'BEGIN {
    drop = b - d
    recover = a - d
    if (drop < 3)    { print "FAIL: the music barely moved (" drop " dB)"; exit 1 }
    if (recover < 3) { print "FAIL: the music never came back up"; exit 1 }
    printf "  ducked by %.1f dB and recovered\n", drop
}'

echo
echo "PASS"
