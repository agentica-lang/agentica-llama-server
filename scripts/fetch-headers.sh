#!/usr/bin/env bash
# The release archive ships no headers. The struct layouts and signatures in src/llama_server/llama.agc are
# copied from llama.h of the same tag; this fetches it (with the headers it includes) for `make check-bindings`.
set -euo pipefail
TAG="b12359"
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/deps/headers"
if [ "$(cat "$dest/TAG" 2>/dev/null)" = "$TAG" ]; then
  echo "already fetched: $dest"
  exit 0
fi
rm -rf "$dest"
mkdir -p "$dest"
for f in include/llama.h ggml/include/ggml.h ggml/include/ggml-alloc.h ggml/include/ggml-backend.h \
  ggml/include/ggml-cpu.h ggml/include/ggml-opt.h ggml/include/gguf.h; do
  curl -fsL "https://raw.githubusercontent.com/ggml-org/llama.cpp/$TAG/$f" -o "$dest/$(basename "$f")"
done
echo "$TAG" > "$dest/TAG"
