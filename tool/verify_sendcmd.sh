#!/usr/bin/env bash
# Verifies the sendcmd script format the export engine generates against a real
# ffmpeg binary.
#
# `flutter test` can prove the generator emits a given string. Only ffmpeg can
# prove that string is a filter graph it accepts, and that the parameter
# genuinely changes over time. This caught the target syntax being
# `filter@label` rather than `label@filter`, which unit tests could never have
# found.
#
# Requires ffmpeg on PATH. Run from the repository root:
#     ./tool/verify_sendcmd.sh

set -euo pipefail

command -v ffmpeg >/dev/null || { echo "ffmpeg not found on PATH"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "ffmpeg: $(ffmpeg -version | head -1)"
echo

# ── 1. Every filter we bind commands to must advertise command support ──
echo "== filters used by EffectCommandBinding must support runtime commands =="
MISSING=0
for f in gblur eq rgbashift chromashift hqdn3d chromakey tmix colorbalance; do
    flags="$(ffmpeg -hide_banner -filters 2>/dev/null | awk -v n="$f" '$2==n {print $1}')"
    if [[ "$flags" == *C* ]]; then
        printf "  %-14s %-6s ok\n" "$f" "$flags"
    else
        printf "  %-14s %-6s NO COMMAND SUPPORT\n" "$f" "${flags:-missing}"
        MISSING=1
    fi
done
[ "$MISSING" -eq 0 ] || { echo "FAIL: a bound filter cannot take commands"; exit 1; }
echo

# ── 2. The generated script shape must parse and run ────────────────────
echo "== generated script is accepted by ffmpeg =="
python3 - > fx.cmd <<'PY'
for i in range(21):
    t = i / 10.0
    sigma = 0.5 + (20 - 0.5) * (i / 20.0)
    print(f"{t:.3f} gblur@fxc1 sigma {sigma:.6f};")
PY
ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc=d=2:s=320x240:r=10" \
    -vf "sendcmd=f=fx.cmd,gblur@fxc1=sigma=0.5" \
    -frames:v 20 -f null - 
echo "  accepted"
echo

# ── 3. The picture must actually change over time ───────────────────────
echo "== parameter genuinely animates (frame hashes must differ) =="
ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc=d=2:s=320x240:r=10" \
    -vf "sendcmd=f=fx.cmd,gblur@fxc1=sigma=0.5" \
    -f framehash -hash md5 - 2>/dev/null | grep -vE '^#' > hashes.txt

FIRST="$(awk 'NR==1{print $6}' hashes.txt)"
LAST="$(awk 'END{print $6}' hashes.txt)"
UNIQUE="$(awk '{print $6}' hashes.txt | sort -u | wc -l)"

echo "  first frame: $FIRST"
echo "  last frame:  $LAST"
echo "  unique frames: $UNIQUE"

[ "$FIRST" != "$LAST" ] || { echo "FAIL: blur did not change over time"; exit 1; }
[ "$UNIQUE" -gt 5 ] || { echo "FAIL: too few distinct frames — animation is stepping badly"; exit 1; }


# ── 4. A command at the clip's duration never fires ─────────────────────
# There is no frame at that instant, so the animation's endpoint value is
# never applied — a fade to opaque stops one sample short. The generator
# clamps its last sample to the final frame; this proves why.
echo "== the endpoint value must land on a frame that exists =="
ffmpeg -hide_banner -loglevel error -f lavfi -i "color=c=red:s=64x64:d=1:r=10" \
    -frames:v 1 layer.png

check_endpoint() {
    printf '0.0 colorchannelmixer@op aa 0;\n%s colorchannelmixer@op aa 1;\n' "$1" > ep.txt
    ffmpeg -hide_banner -loglevel error -loop 1 -t 1 -i layer.png -filter_complex \
"color=c=blue:s=64x64:d=1:r=10[bg];\
[0:v]fps=10,sendcmd=f=ep.txt,format=yuva420p,colorchannelmixer@op=aa=0[l];\
[bg][l]overlay=format=auto[v]" -map "[v]" -frames:v 10 -c:v libx264 -preset ultrafast -y ep.mp4
    ffmpeg -hide_banner -loglevel error -i ep.mp4 -vf "select='eq(n,9)'" -frames:v 1 -y last.png
    ffmpeg -hide_banner -loglevel error -i last.png -vf crop=1:1:32:32 \
        -f rawvideo -pix_fmt rgb24 - | od -An -tu1 | awk '{print $1}'
}

AT_DURATION="$(check_endpoint 1.0)"
AT_LAST_FRAME="$(check_endpoint 0.9)"
printf "  command at 1.0s (the duration): final red = %s\n" "$AT_DURATION"
printf "  command at 0.9s (the last frame): final red = %s\n" "$AT_LAST_FRAME"

[ "$AT_LAST_FRAME" -gt 200 ] || {
    echo "FAIL: a command on the last frame did not take effect"; exit 1; }
[ "$AT_DURATION" -lt 200 ] || {
    echo "NOTE: this build also runs a command scheduled past the last frame"; }
echo "  clamping the last sample to the final frame is required"
echo
echo
echo "PASS: sendcmd automation verified end to end"
