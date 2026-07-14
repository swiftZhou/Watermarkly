#!/bin/bash
set -euo pipefail

# Copies the MIT-licensed MI-GAN 256 Core ML package used for fast Retouch.
# Source project: https://github.com/tatsuya-ogawa/MI-GAN-CoreML
# Original model: Picsart-AI-Research/MI-GAN (MIT)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Watermarkly/Watermarkly/migan_coreml.mlpackage"
TMP="$(mktemp -d)"
REPO_URL="${MIGAN_REPO_URL:-https://github.com/tatsuya-ogawa/MI-GAN-CoreML.git}"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "Cloning MI-GAN Core ML package..."
git clone --depth 1 "$REPO_URL" "$TMP/repo"

SRC="$TMP/repo/migan_coreml.mlpackage"
if [ ! -d "$SRC" ]; then
  echo "migan_coreml.mlpackage not found in repo."
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$SRC" "$DEST"

echo "MI-GAN model ready at:"
echo "  $DEST"
echo "Rebuild in Xcode — Retouch uses MI-GAN 256 for fast on-device inpainting."
