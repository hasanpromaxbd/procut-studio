#!/usr/bin/env bash
# Compiles every shader for both backends.
#
# `flutter analyze` never looks at .frag files, and `flutter test` only
# compiles them as a side effect of building the asset bundle — where a failure
# surfaces as a tool crash with a GitHub issue link rather than a readable
# error. This runs impellerc directly and prints the actual compiler message.
#
# SkSL is the strict target: Impeller accepts constructs Skia rejects (array
# initializers, some reserved words), and Skia is still the fallback backend on
# devices without a usable Vulkan driver.
#
#     ./tool/verify_shaders.sh

set -uo pipefail

FLUTTER_ROOT="${FLUTTER_ROOT:-$(dirname "$(dirname "$(command -v flutter)")")}"
IMPELLERC="$(find "$FLUTTER_ROOT/bin/cache/artifacts/engine" -name impellerc 2>/dev/null | head -1)"
GLSL="$(find "$FLUTTER_ROOT/bin/cache/artifacts/engine" -name runtime_effect.glsl 2>/dev/null | head -1)"

[ -n "$IMPELLERC" ] || { echo "impellerc not found — run 'flutter precache' first"; exit 1; }
SHADER_LIB="$(dirname "$GLSL")/.."

failed=0
for f in shaders/*.frag; do
    out="$("$IMPELLERC" --sksl --iplr \
        --input="$f" --sl=/tmp/_shader.sksl --spirv=/tmp/_shader.spv \
        --include=shaders --include="$SHADER_LIB" 2>&1)"
    if [ -n "$out" ]; then
        printf "  %-32s FAIL\n" "$(basename "$f")"
        echo "$out" | sed 's/^/      /'
        failed=1
    else
        printf "  %-32s ok\n" "$(basename "$f")"
    fi
done

rm -f /tmp/_shader.sksl /tmp/_shader.spv
if [ "$failed" -ne 0 ]; then echo; echo "FAIL: a shader did not compile"; exit 1; fi
echo
echo "PASS: all shaders compile for SkSL and Impeller"
