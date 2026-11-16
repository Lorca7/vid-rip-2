#!/usr/bin/env bash
# Downloads the command-line tools VidRip bundles and makes universal (Apple Silicon + Intel)
# binaries in build/tools:
#   yt-dlp  – downloads from YouTube            https://github.com/yt-dlp/yt-dlp
#   ffmpeg  – cuts and converts video           https://github.com/eugeneware/ffmpeg-static
#   deno    – JavaScript runtime yt-dlp needs   https://github.com/denoland/deno
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="build/tools"
WORK="build/tools-download"
FFMPEG_RELEASE="${FFMPEG_RELEASE:-b6.1.1}"
mkdir -p "$OUT" "$WORK"

fetch() { # url dest
  echo "→ $1"
  curl --fail --location --retry 4 --retry-delay 3 --silent --show-error -o "$2" "$1"
}

if [[ ! -x "$OUT/yt-dlp" ]]; then
  fetch "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" "$OUT/yt-dlp"
  chmod +x "$OUT/yt-dlp"
fi

if [[ ! -x "$OUT/ffmpeg" ]]; then
  fetch "https://github.com/eugeneware/ffmpeg-static/releases/download/$FFMPEG_RELEASE/ffmpeg-darwin-arm64.gz" "$WORK/ffmpeg-arm64.gz"
  fetch "https://github.com/eugeneware/ffmpeg-static/releases/download/$FFMPEG_RELEASE/ffmpeg-darwin-x64.gz" "$WORK/ffmpeg-x64.gz"
  gunzip -f "$WORK/ffmpeg-arm64.gz" "$WORK/ffmpeg-x64.gz"
  lipo -create "$WORK/ffmpeg-arm64" "$WORK/ffmpeg-x64" -output "$OUT/ffmpeg"
  chmod +x "$OUT/ffmpeg"
fi

if [[ ! -x "$OUT/deno" ]]; then
  fetch "https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip" "$WORK/deno-arm64.zip"
  fetch "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-apple-darwin.zip" "$WORK/deno-x64.zip"
  rm -rf "$WORK/deno-arm64" "$WORK/deno-x64"
  unzip -q -o "$WORK/deno-arm64.zip" -d "$WORK/deno-arm64"
  unzip -q -o "$WORK/deno-x64.zip" -d "$WORK/deno-x64"
  lipo -create "$WORK/deno-arm64/deno" "$WORK/deno-x64/deno" -output "$OUT/deno"
  chmod +x "$OUT/deno"
fi

for tool in yt-dlp ffmpeg deno; do
  printf '%-7s ' "$tool"; lipo -archs "$OUT/$tool"
done
