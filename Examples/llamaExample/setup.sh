#!/usr/bin/env bash
set -euo pipefail

RELEASE="b9305"
ZIP_URL="https://github.com/ggml-org/llama.cpp/releases/download/${RELEASE}/llama-${RELEASE}-xcframework.zip"
DEST="LlamaPackage/Frameworks/llama.xcframework"

if [ -d "$DEST" ]; then
  echo "llama.xcframework already present, skipping download."
  exit 0
fi

echo "Downloading llama.cpp xcframework (${RELEASE})..."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -L --progress-bar -o "$TMP/llama.zip" "$ZIP_URL"

echo "Extracting..."
unzip -q "$TMP/llama.zip" -d "$TMP/unzipped"

mkdir -p LlamaPackage/Frameworks
cp -R "$TMP/unzipped/build-apple/llama.xcframework" LlamaPackage/Frameworks/

echo "Done → $DEST"
