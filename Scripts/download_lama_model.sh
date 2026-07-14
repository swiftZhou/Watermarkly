#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="$ROOT/Models/LaMa.mlpackage"
DEST="$ROOT/Watermarkly/Watermarkly/LaMa.mlpackage"
BASE_URL="${LAMA_MODEL_BASE_URL:-https://hf-mirror.com/jerhoads/lama-coreml/resolve/main/LaMa.mlpackage}"
# If mirror fails:
#   LAMA_MODEL_BASE_URL="https://huggingface.co/jerhoads/lama-coreml/resolve/main/LaMa.mlpackage" bash Scripts/download_lama_model.sh
EXPECTED_BYTES=204086656

mkdir -p "$STAGING/Data/com.apple.CoreML/weights"

echo "Downloading LaMa Core ML model (~195 MB) into staging:"
echo "  $STAGING"
echo "Source: $BASE_URL"

curl -L --fail --http1.1 --retry 20 --retry-delay 2 -C - \
  "$BASE_URL/Manifest.json" \
  -o "$STAGING/Manifest.json"

curl -L --fail --http1.1 --retry 20 --retry-delay 2 -C - \
  "$BASE_URL/Data/com.apple.CoreML/model.mlmodel" \
  -o "$STAGING/Data/com.apple.CoreML/model.mlmodel"

curl -L --fail --http1.1 --retry 20 --retry-delay 2 -C - \
  "$BASE_URL/Data/com.apple.CoreML/weights/weight.bin" \
  -o "$STAGING/Data/com.apple.CoreML/weights/weight.bin"

BYTES=$(stat -f%z "$STAGING/Data/com.apple.CoreML/weights/weight.bin" 2>/dev/null || stat -c%s "$STAGING/Data/com.apple.CoreML/weights/weight.bin")
if [ "$BYTES" -lt "$EXPECTED_BYTES" ]; then
  echo "Download incomplete ($BYTES / $EXPECTED_BYTES bytes). Re-run this script."
  exit 1
fi

echo "Installing model into Xcode sources..."
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$STAGING" "$DEST"

echo "LaMa model ready ($BYTES bytes) at:"
echo "  $DEST"
echo "Rebuild the app in Xcode — Retouch will use AI inpainting on finger release."
