#!/usr/bin/env bash
# Fetches a GGUF model from Hugging Face into deps/, checked against its sha256. Never committed.
# No arguments: Qwen2.5-0.5B-Instruct Q4_K_M, the model the tests use. Otherwise: REPO FILE SHA256.
set -euo pipefail
if [ "$#" -ne 0 ] && [ "$#" -ne 3 ]; then
  echo "usage: $0 [REPO FILE SHA256]" >&2; exit 2
fi
REPO="${1:-Qwen/Qwen2.5-0.5B-Instruct-GGUF}"
FILE="${2:-qwen2.5-0.5b-instruct-q4_k_m.gguf}"
SHA256="${3:-74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db}"
URL="https://huggingface.co/$REPO/resolve/main/$FILE"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/deps/$(basename "$FILE")"
mkdir -p "$root/deps"
if [ -f "$out" ] && echo "$SHA256  $out" | sha256sum -c - >/dev/null 2>&1; then
  echo "already fetched: $out"; exit 0
fi
curl -fL -o "$out" "$URL"
echo "$SHA256  $out" | sha256sum -c -
