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
#   └── voice_styles/
#       ├── F1.json ... F5.json
#       └── M1.json ... M5.json

set -e

# Configuration
SUPERTONIC_SOURCE="${SUPERTONIC_SOURCE:-$HOME/projects/supertonic/assets}"
OUTPUT_DIR="${OUTPUT_DIR:-./repackaged-voices}"
WORK_DIR="/tmp/supertonic-packaging"
ARCHIVE_NAME="supertonic-engine-v1"
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
            echo "  --upload  Upload archive to GitHub release ($GITHUB_REPO, tag $RELEASE_TAG)"
            exit 0
            ;;
    esac
done

# Verify dependencies
for cmd in tar zstd shasum; do
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

MODELS=(text_encoder duration_predictor vector_estimator vocoder)
for model in "${MODELS[@]}"; do
    if [[ ! -d "$COREML_DIR/$model.mlpackage" ]]; then
        echo "Error: CoreML model not found: $COREML_DIR/$model.mlpackage"
        exit 1
    fi
done

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
shasum -a 256 "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" > "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst.sha256"

# Report
COMPRESSED_SIZE=$(du -sh "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" | cut -f1)
SHA256=$(cut -d' ' -f1 "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst.sha256")

echo ""
echo "=== Done ==="
echo "Archive:  $OUTPUT_DIR/$ARCHIVE_NAME.tar.zst ($COMPRESSED_SIZE)"
echo "SHA256:   $SHA256"
echo "Checksum: $OUTPUT_DIR/$ARCHIVE_NAME.tar.zst.sha256"

# Upload to GitHub release
if $UPLOAD; then
    echo ""
    echo "Uploading to GitHub release ($GITHUB_REPO, tag $RELEASE_TAG)..."
    gh release upload "$RELEASE_TAG" \
        "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" \
        "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst.sha256" \
        --repo "$GITHUB_REPO" --clobber
    echo "Upload complete."
fi

# Clean up work directory
rm -rf "$WORK_DIR"
