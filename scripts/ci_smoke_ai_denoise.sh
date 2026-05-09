#!/usr/bin/env bash
# =============================================================================
# CI smoke test: AI denoise + non-ASCII path verification
# =============================================================================
# Two end-to-end smoke runs against the built binary:
#
# 1. ASCII path: exercises NcnnDenoiser::initialize(), including the Vulkan
#    loader probe and CPU fallback. Catches the class of issues seen in
#    #30 / #31 -- where Vulkan loading fails on macOS without MoltenVK and
#    the AI denoise init path crashes with SIGBUS instead of falling back
#    to CPU. A plain `--version` smoke test does not exercise this path.
#
# 2. CJK path: exercises the Windows activeCodePage UTF-8 manifest by
#    feeding the binary a filename whose characters are outside any single
#    Windows ANSI code page (mixed Traditional Chinese + Japanese kana).
#    Catches argv / fs::path / cv::imread CP_ACP regressions on Windows
#    (issue #33). Linux/macOS treat this as a UTF-8 native path and pass
#    trivially.
#
# Usage: ci_smoke_ai_denoise.sh <path-to-binary>
# =============================================================================
set -euo pipefail

BIN="${1:?usage: $0 <path-to-binary>}"

if [[ ! -x "$BIN" && ! -f "$BIN" ]]; then
    echo "ERROR: binary not found: $BIN" >&2
    exit 2
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

INPUT="$WORKDIR/smoke_in.png"
OUTPUT="$WORKDIR/smoke_out.png"

PY=python3
command -v "$PY" >/dev/null 2>&1 || PY=python

echo "--- generating 512x512 synthetic test image (using $PY) ---"
"$PY" - "$INPUT" <<'PY_EOF'
import struct, sys, zlib

def png(w, h, color=(128, 128, 128)):
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    row = b"\0" + bytes(color) * w
    raw = row * h
    idat = chunk(b"IDAT", zlib.compress(raw))
    iend = chunk(b"IEND", b"")
    return sig + ihdr + idat + iend

with open(sys.argv[1], "wb") as f:
    f.write(png(512, 512))
PY_EOF
ls -lh "$INPUT"

echo "--- running AI denoise pipeline ---"
# --force         skip detection (no real watermark on a uniform image)
# --region br:auto  process the bottom-right region at the Gemini default position
# --denoise ai    exercise the NCNN/Vulkan/CPU dispatch path
"$BIN" --force --region br:auto --denoise ai -i "$INPUT" -o "$OUTPUT"
RC=$?

if [[ $RC -ne 0 ]]; then
    echo "ERROR: binary exited with code $RC" >&2
    exit $RC
fi

if [[ ! -f "$OUTPUT" ]]; then
    echo "ERROR: expected output file not produced: $OUTPUT" >&2
    exit 3
fi

OUT_SIZE=$(wc -c <"$OUTPUT")
if [[ $OUT_SIZE -lt 1000 ]]; then
    echo "ERROR: output file suspiciously small ($OUT_SIZE bytes)" >&2
    exit 4
fi

echo "--- AI denoise smoke test PASSED (output=$OUT_SIZE bytes) ---"

# =============================================================================
# CJK / non-ASCII path smoke test
# =============================================================================
# Exercises the activeCodePage UTF-8 manifest by feeding the binary a path
# whose characters are guaranteed to fall outside any single Windows ANSI
# code page (mixed Traditional Chinese + Japanese hiragana). On Windows
# without our manifest applied, argv would arrive with characters replaced
# by '?', fs::path(string) would corrupt internally, and cv::imread would
# fail. With the manifest the entire chain becomes UTF-8 transparent.
#
# Linux/macOS file systems are UTF-8 native, so this test passes there
# regardless and serves as a regression guard.
# =============================================================================
CJK_INPUT="$WORKDIR/動漫角色電眼繪製技法 - きらめく瞳の描き方.png"
CJK_OUTPUT="$WORKDIR/出力_中文_テスト.png"

echo "--- creating CJK-named copy of test image ---"
cp "$INPUT" "$CJK_INPUT"
ls -lh "$CJK_INPUT"

echo "--- running AI denoise pipeline on CJK path ---"
"$BIN" --force --region br:auto --denoise ai -i "$CJK_INPUT" -o "$CJK_OUTPUT"
RC=$?

if [[ $RC -ne 0 ]]; then
    echo "ERROR: CJK path test failed with exit code $RC" >&2
    echo "       (likely a Windows code-page or argv encoding regression)" >&2
    exit $RC
fi

if [[ ! -f "$CJK_OUTPUT" ]]; then
    echo "ERROR: CJK output file not produced: $CJK_OUTPUT" >&2
    exit 5
fi

CJK_SIZE=$(wc -c <"$CJK_OUTPUT")
if [[ $CJK_SIZE -lt 1000 ]]; then
    echo "ERROR: CJK output file suspiciously small ($CJK_SIZE bytes)" >&2
    exit 6
fi

echo "--- CJK path smoke test PASSED (output=$CJK_SIZE bytes) ---"
