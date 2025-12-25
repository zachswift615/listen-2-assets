#!/bin/bash
# scripts/repackage-all-english-voices.sh
# Download, repackage, and upload all medium quality English voices as .tar.zst
#
# Usage: ./repackage-all-english-voices.sh [--upload]
#        --upload: Also upload to GitHub release after repackaging

set -e

# Configuration
WORK_DIR="${WORK_DIR:-/tmp/voice-repackaging}"
OUTPUT_DIR="${OUTPUT_DIR:-./repackaged-voices}"
ZSTD_LEVEL=19  # Maximum compression
SOURCE_RELEASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"
GITHUB_REPO="zachswift615/listen-2-assets"
RELEASE_TAG="voices-v1"

# All medium quality English voices
VOICES=(
    # en_US voices (16)
    "en_US-arctic-medium"
    "en_US-bryce-medium"
    "en_US-hfc_female-medium"
    "en_US-hfc_male-medium"
    "en_US-joe-medium"
    "en_US-john-medium"
    "en_US-kristin-medium"
    "en_US-kusal-medium"
    "en_US-l2arctic-medium"
    "en_US-lessac-medium"
    "en_US-libritts_r-medium"
    "en_US-ljspeech-medium"
    "en_US-norman-medium"
    "en_US-reza_ibrahim-medium"
    "en_US-ryan-medium"
    "en_US-sam-medium"
    # en_GB voices (10)
    "en_GB-alan-medium"
    "en_GB-alba-medium"
    "en_GB-aru-medium"
    "en_GB-cori-medium"
    "en_GB-jenny_dioco-medium"
    "en_GB-northern_english_male-medium"
    "en_GB-semaine-medium"
    "en_GB-southern_english_female-medium"
    "en_GB-southern_english_male-medium"
    "en_GB-vctk-medium"
)

UPLOAD=false
if [[ "$1" == "--upload" ]]; then
    UPLOAD=true
fi

# Check dependencies
for cmd in curl zstd tar; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd not installed"
        exit 1
    fi
done

if $UPLOAD && ! command -v gh &> /dev/null; then
    echo "Error: gh (GitHub CLI) required for --upload"
    exit 1
fi

# Setup directories
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

echo "================================================"
echo "Repackaging ${#VOICES[@]} voices from bz2 to zstd"
echo "================================================"
echo ""

TOTAL_BZ2=0
TOTAL_ZSTD=0
SUCCESS=0
FAILED=0

for voice in "${VOICES[@]}"; do
    echo "----------------------------------------"
    echo "Processing: $voice"

    BZ2_NAME="vits-piper-${voice}.tar.bz2"
    ZSTD_NAME="vits-piper-${voice}.tar.zst"
    BZ2_URL="${SOURCE_RELEASE}/${BZ2_NAME}"

    BZ2_PATH="$WORK_DIR/$BZ2_NAME"
    TAR_PATH="$WORK_DIR/${voice}.tar"
    ZSTD_PATH="$OUTPUT_DIR/$ZSTD_NAME"

    # Skip if already exists
    if [[ -f "$ZSTD_PATH" ]]; then
        echo "  Already exists: $ZSTD_NAME"
        ZSTD_SIZE=$(stat -f%z "$ZSTD_PATH" 2>/dev/null || stat -c%s "$ZSTD_PATH")
        TOTAL_ZSTD=$((TOTAL_ZSTD + ZSTD_SIZE))
        ((SUCCESS++))
        continue
    fi

    # Download bz2
    echo "  Downloading..."
    if ! curl -L --progress-bar -o "$BZ2_PATH" "$BZ2_URL"; then
        echo "  Download failed"
        ((FAILED++))
        continue
    fi

    BZ2_SIZE=$(stat -f%z "$BZ2_PATH" 2>/dev/null || stat -c%s "$BZ2_PATH")
    TOTAL_BZ2=$((TOTAL_BZ2 + BZ2_SIZE))
    echo "  Downloaded: $((BZ2_SIZE/1048576)) MB"

    # Decompress bz2 to tar
    echo "  Decompressing bz2..."
    if ! bzcat "$BZ2_PATH" > "$TAR_PATH"; then
        echo "  Decompression failed"
        rm -f "$BZ2_PATH" "$TAR_PATH"
        ((FAILED++))
        continue
    fi
    rm -f "$BZ2_PATH"  # Free space

    # Recompress with zstd
    echo "  Compressing with zstd (level $ZSTD_LEVEL)..."
    if ! zstd -$ZSTD_LEVEL -T0 --long=31 "$TAR_PATH" -o "$ZSTD_PATH" --quiet; then
        echo "  Zstd compression failed"
        rm -f "$TAR_PATH"
        ((FAILED++))
        continue
    fi
    rm -f "$TAR_PATH"  # Free space

    ZSTD_SIZE=$(stat -f%z "$ZSTD_PATH" 2>/dev/null || stat -c%s "$ZSTD_PATH")
    TOTAL_ZSTD=$((TOTAL_ZSTD + ZSTD_SIZE))

    SAVINGS=$(( (BZ2_SIZE - ZSTD_SIZE) * 100 / BZ2_SIZE ))
    echo "  Created: $ZSTD_NAME (${SAVINGS}% smaller)"

    # Generate SHA256
    shasum -a 256 "$ZSTD_PATH" > "${ZSTD_PATH}.sha256"

    ((SUCCESS++))
done

echo ""
echo "================================================"
echo "Summary"
echo "================================================"
echo "Successful: $SUCCESS / ${#VOICES[@]}"
echo "Failed: $FAILED"
echo ""
echo "Total bz2 size:  $((TOTAL_BZ2/1048576)) MB"
echo "Total zstd size: $((TOTAL_ZSTD/1048576)) MB"
if [[ $TOTAL_BZ2 -gt 0 ]]; then
    OVERALL_SAVINGS=$(( (TOTAL_BZ2 - TOTAL_ZSTD) * 100 / TOTAL_BZ2 ))
    echo "Overall savings: ${OVERALL_SAVINGS}%"
fi
echo ""
echo "Output directory: $OUTPUT_DIR"

# Upload if requested
if $UPLOAD && [[ $SUCCESS -gt 0 ]]; then
    echo ""
    echo "================================================"
    echo "Uploading to GitHub Release"
    echo "================================================"
    echo "Repo: $GITHUB_REPO"
    echo "Tag:  $RELEASE_TAG"

    echo "Creating/updating release..."
    gh release create "$RELEASE_TAG" \
        --repo "$GITHUB_REPO" \
        --title "Listen2 Voice Models" \
        --notes "Piper TTS voices repackaged as .tar.zst for faster decompression" \
        2>/dev/null || true

    for zst_file in "$OUTPUT_DIR"/*.tar.zst; do
        if [[ -f "$zst_file" ]]; then
            echo "Uploading: $(basename "$zst_file")"
            gh release upload "$RELEASE_TAG" "$zst_file" --repo "$GITHUB_REPO" --clobber
        fi
    done

    echo ""
    echo "Upload complete!"
    echo "Release URL: https://github.com/$GITHUB_REPO/releases/tag/$RELEASE_TAG"
fi

echo ""
echo "Done!"
