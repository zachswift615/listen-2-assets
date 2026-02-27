#!/bin/bash
# scripts/package-supertonic-engine.sh
# Package Supertonic CoreML models + voice styles as .tar.zst for distribution
#
# Usage: ./package-supertonic-engine.sh [--upload]
#        --upload: Upload to GitHub release after packaging
#
# Output:
#   repackaged-voices/supertonic-engine-v1.tar.zst       (~75 MB)
#   repackaged-voices/supertonic-engine-v1.tar.zst.sha256
#
# The archive contains:
#   supertonic-engine-v1/
#   ├── text_encoder.mlpackage/
#   ├── duration_predictor.mlpackage/
#   ├── vector_estimator.mlpackage/
#   ├── vocoder.mlpackage/
#   ├── unicode_indexer.json
#   └── voice_styles/
#       ├── F1.json ... F5.json
#       └── M1.json ... M5.json
#
# On --upload, the script also:
#   1. Computes SHA256 of the archive
#   2. Bumps manifestVersion in supertonic-manifest.json
#   3. Updates engineSHA256 and engineSizeMB in the manifest
#   4. Uploads archive + manifest to the GitHub release

set -e

# Configuration
SUPERTONIC_SOURCE="${SUPERTONIC_SOURCE:-$HOME/projects/supertonic/assets}"
OUTPUT_DIR="${OUTPUT_DIR:-./repackaged-voices}"
WORK_DIR="/tmp/supertonic-packaging"
ARCHIVE_NAME="supertonic-engine-v1"
MANIFEST="$OUTPUT_DIR/supertonic-manifest.json"
ZSTD_LEVEL=19
GITHUB_REPO="zachswift615/listen-2-assets"
RELEASE_TAG="voices-v1"

# Parse arguments
UPLOAD=false
for arg in "$@"; do
    case "$arg" in
        --upload) UPLOAD=true ;;
        -h|--help)
            echo "Usage: $0 [--upload]"
            echo "  --upload  Upload archive + updated manifest to GitHub release ($GITHUB_REPO, tag $RELEASE_TAG)"
            exit 0
            ;;
    esac
done

# Verify dependencies
for cmd in tar zstd shasum jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: '$cmd' not found. Install it first."
        exit 1
    fi
done

if $UPLOAD && ! command -v gh &>/dev/null; then
    echo "Error: 'gh' (GitHub CLI) not found. Install it for --upload."
    exit 1
fi

# Verify source assets exist
COREML_DIR="$SUPERTONIC_SOURCE/coreml"
STYLES_DIR="$SUPERTONIC_SOURCE/voice_styles"
ONNX_DIR="$SUPERTONIC_SOURCE/onnx"

MODELS=(text_encoder duration_predictor vector_estimator vocoder)
for model in "${MODELS[@]}"; do
    if [[ ! -d "$COREML_DIR/$model.mlpackage" ]]; then
        echo "Error: CoreML model not found: $COREML_DIR/$model.mlpackage"
        exit 1
    fi
done

if [[ ! -f "$ONNX_DIR/unicode_indexer.json" ]]; then
    echo "Error: Unicode indexer not found: $ONNX_DIR/unicode_indexer.json"
    exit 1
fi

VOICES=(F1 F2 F3 F4 F5 M1 M2 M3 M4 M5)
for voice in "${VOICES[@]}"; do
    if [[ ! -f "$STYLES_DIR/$voice.json" ]]; then
        echo "Error: Voice style not found: $STYLES_DIR/$voice.json"
        exit 1
    fi
done

echo "=== Packaging Supertonic Engine ==="
echo "Source: $SUPERTONIC_SOURCE"
echo "Output: $OUTPUT_DIR/$ARCHIVE_NAME.tar.zst"
echo ""

# Clean work directory
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/$ARCHIVE_NAME/voice_styles"
mkdir -p "$OUTPUT_DIR"

# Copy CoreML models
echo "Copying CoreML models..."
for model in "${MODELS[@]}"; do
    echo "  $model.mlpackage"
    cp -r "$COREML_DIR/$model.mlpackage" "$WORK_DIR/$ARCHIVE_NAME/"
done

# Copy voice styles
echo "Copying voice styles..."
for voice in "${VOICES[@]}"; do
    echo "  $voice.json"
    cp "$STYLES_DIR/$voice.json" "$WORK_DIR/$ARCHIVE_NAME/voice_styles/"
done

# Copy unicode indexer (required for text tokenization)
echo "Copying unicode indexer..."
cp "$ONNX_DIR/unicode_indexer.json" "$WORK_DIR/$ARCHIVE_NAME/"

# Show sizes
echo ""
echo "Uncompressed sizes:"
du -sh "$WORK_DIR/$ARCHIVE_NAME"
for model in "${MODELS[@]}"; do
    du -sh "$WORK_DIR/$ARCHIVE_NAME/$model.mlpackage"
done
du -sh "$WORK_DIR/$ARCHIVE_NAME/voice_styles"

# Create tar archive
echo ""
echo "Creating tar archive..."
tar cf "$WORK_DIR/$ARCHIVE_NAME.tar" -C "$WORK_DIR" "$ARCHIVE_NAME/"

# Compress with zstd
echo "Compressing with zstd (level $ZSTD_LEVEL)..."
zstd -"$ZSTD_LEVEL" -T0 --long=31 "$WORK_DIR/$ARCHIVE_NAME.tar" -o "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" --force

# Generate SHA256
echo "Generating SHA256 checksum..."
SHA256=$(shasum -a 256 "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" | cut -d' ' -f1)
echo "$SHA256  $OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" > "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst.sha256"

# Get compressed size in MB
COMPRESSED_SIZE=$(du -sh "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" | cut -f1)
COMPRESSED_BYTES=$(stat -f%z "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" 2>/dev/null || stat -c%s "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" 2>/dev/null)
SIZE_MB=$(( (COMPRESSED_BYTES + 1048575) / 1048576 ))

# Report
echo ""
echo "=== Done ==="
echo "Archive:  $OUTPUT_DIR/$ARCHIVE_NAME.tar.zst ($COMPRESSED_SIZE)"
echo "SHA256:   $SHA256"
echo "Checksum: $OUTPUT_DIR/$ARCHIVE_NAME.tar.zst.sha256"

# Update manifest and upload
if $UPLOAD; then
    echo ""

    # Verify manifest exists
    if [[ ! -f "$MANIFEST" ]]; then
        echo "Error: Manifest not found at $MANIFEST"
        exit 1
    fi

    # Read current manifest version, bump it
    OLD_VERSION=$(jq '.manifestVersion // 0' "$MANIFEST")
    NEW_VERSION=$((OLD_VERSION + 1))

    # Update manifest: SHA256, size, and version
    jq --arg sha "$SHA256" \
       --argjson size "$SIZE_MB" \
       --argjson ver "$NEW_VERSION" \
       '.engineSHA256 = $sha | .engineSizeMB = $size | .manifestVersion = $ver' \
       "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"

    echo "Updated manifest:"
    echo "  manifestVersion: $OLD_VERSION -> $NEW_VERSION"
    echo "  engineSHA256:    $SHA256"
    echo "  engineSizeMB:    $SIZE_MB"
    echo ""

    echo "Uploading to GitHub release ($GITHUB_REPO, tag $RELEASE_TAG)..."
    gh release upload "$RELEASE_TAG" \
        "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" \
        "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst.sha256" \
        "$MANIFEST" \
        --repo "$GITHUB_REPO" --clobber
    echo "Upload complete."
fi

# Clean up work directory
rm -rf "$WORK_DIR"
