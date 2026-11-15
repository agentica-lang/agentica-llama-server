#!/usr/bin/env bash
# Fetches the pinned prebuilt CPU llama.cpp release (libllama.so, ggml libs,
# llama-server) into deps/llama.cpp. Nothing here is committed.
set -euo pipefail
TAG="b12426"
FILE="llama-${TAG}-bin-ubuntu-x64.tar.gz"
URL="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/${FILE}"
SHA256="011212b7a6052a213034d4c313f99f131cb09fb5fb5a4ee61cd7572b81febf67"

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/deps/llama.cpp"
mkdir -p "$root/deps"
if [ -x "$dest/llama-server" ] && [ "$(cat "$dest/TAG" 2>/dev/null)" = "$TAG" ]; then
  echo "already fetched: $dest"
else
  tmp="$root/deps/$FILE"
  curl -fL -o "$tmp" "$URL"
  echo "$SHA256  $tmp" | sha256sum -c -
  rm -rf "$dest"
  mkdir -p "$dest"
  tar -xzf "$tmp" -C "$dest" --strip-components=1
  rm -f "$tmp"
  echo "$TAG" > "$dest/TAG"
fi

# The manifest wants native libraries under native/linux/. Link every shared
# library there: RUNPATH=$ORIGIN of libllama.so then finds libggml*.so, and
# ggml loads libggml-cpu-*.so from the same folder.
mkdir -p "$root/native/linux"
find "$root/native/linux" -xtype l -delete
for lib in "$dest"/*.so*; do
  ln -sf "../../deps/llama.cpp/$(basename "$lib")" "$root/native/linux/$(basename "$lib")"
done
