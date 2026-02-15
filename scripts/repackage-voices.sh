#!/bin/bash
# scripts/repackage-voices.sh
# Discover, repackage, and upload Piper TTS voices as .tar.zst
# Dynamically fetches available voices from sherpa-onnx releases (all qualities)
#
# Usage: ./repackage-voices.sh [language|all] [--upload]
#        language: Language prefix to filter (e.g., "es", "de", "en")
#        all: Process all discovered languages
#        --upload: Also upload NEW files to GitHub release (skips already-uploaded)
#
# Examples:
#   ./repackage-voices.sh es              # All Spanish voices (all qualities)
#   ./repackage-voices.sh all             # Every Piper voice
#   ./repackage-voices.sh es --upload     # Spanish + upload new files

set -e

# Configuration
WORK_DIR="${WORK_DIR:-/tmp/voice-repackaging}"
OUTPUT_DIR="${OUTPUT_DIR:-./repackaged-voices}"
ZSTD_LEVEL=19  # Maximum compression
SHERPA_REPO="k2-fsa/sherpa-onnx"
SHERPA_TAG="tts-models"
SOURCE_RELEASE="https://github.com/$SHERPA_REPO/releases/download/$SHERPA_TAG"
GITHUB_REPO="zachswift615/listen-2-assets"
RELEASE_TAG="voices-v1"

# Parse arguments
LANG_FILTER=""
UPLOAD=false

for arg in "$@"; do
    case "$arg" in
        --upload) UPLOAD=true ;;
        *) LANG_FILTER="$arg" ;;
    esac
done

# Check dependencies
for cmd in curl zstd tar gh; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: $cmd not installed"
        exit 1
    fi
done

# Discover voices from sherpa-onnx release
echo "Fetching voice list from $SHERPA_REPO..."
ALL_BZ2=$(gh api "repos/$SHERPA_REPO/releases/tags/$SHERPA_TAG" \
    --jq '.assets[].name' 2>/dev/null \
    | grep "^vits-piper-" \
    | grep "\.tar\.bz2$" \
    | grep -v "fp16\|int8" \
    | sort)

if [[ -z "$ALL_BZ2" ]]; then
    echo "Error: Could not fetch voice list from GitHub"
    exit 1
fi

TOTAL_AVAILABLE=$(echo "$ALL_BZ2" | wc -l | tr -d ' ')
echo "Found $TOTAL_AVAILABLE voices (excluding fp16/int8 quantized variants)"
echo ""

# Show usage / filter
if [[ -z "$LANG_FILTER" ]]; then
    echo "Usage: $0 [language|all] [--upload]"
    echo ""
    echo "Available languages:"
    echo "$ALL_BZ2" | sed 's/vits-piper-//;s/\.tar\.bz2//' | cut -d'-' -f1 | sort -u | while read -r locale; do
        lang=$(echo "$locale" | cut -d'_' -f1)
        count=$(echo "$ALL_BZ2" | grep "vits-piper-${locale}" | wc -l | tr -d ' ')
        # Only show language code if we haven't printed it yet
        echo "  $locale ($count voices)"
    done
    exit 1
fi

# Filter voices by language
if [[ "$LANG_FILTER" == "all" ]]; then
    FILTERED_BZ2="$ALL_BZ2"
else
    FILTERED_BZ2=$(echo "$ALL_BZ2" | grep "^vits-piper-${LANG_FILTER}" || true)
    if [[ -z "$FILTERED_BZ2" ]]; then
        echo "Error: No voices found for language prefix '$LANG_FILTER'"
        echo ""
        echo "Try one of:"
        echo "$ALL_BZ2" | sed 's/vits-piper-//;s/\.tar\.bz2//' | cut -d'-' -f1 | sort -u | head -20
        exit 1
    fi
fi

VOICE_COUNT=$(echo "$FILTERED_BZ2" | wc -l | tr -d ' ')

# If uploading, fetch existing release assets to skip re-uploads
EXISTING_ASSETS=""
if $UPLOAD; then
    echo "Checking existing release assets..."
    EXISTING_ASSETS=$(gh api "repos/$GITHUB_REPO/releases/tags/$RELEASE_TAG" \
        --jq '.assets[].name' 2>/dev/null || true)
fi

# Setup directories
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

echo "================================================"
echo "Repackaging $VOICE_COUNT voices from bz2 to zstd"
echo "Language filter: ${LANG_FILTER}"
echo "================================================"
echo ""

TOTAL_BZ2=0
TOTAL_ZSTD=0
SUCCESS=0
SKIPPED=0
FAILED=0

echo "$FILTERED_BZ2" | while read -r bz2_name; do
    # Extract voice ID: "vits-piper-es_ES-davefx-medium.tar.bz2" -> "es_ES-davefx-medium"
    voice=$(echo "$bz2_name" | sed 's/^vits-piper-//;s/\.tar\.bz2$//')
    zstd_name="vits-piper-${voice}.tar.zst"

    echo "----------------------------------------"
    echo "Processing: $voice"

    BZ2_URL="${SOURCE_RELEASE}/${bz2_name}"
    BZ2_PATH="$WORK_DIR/$bz2_name"
    TAR_PATH="$WORK_DIR/${voice}.tar"
    ZSTD_PATH="$OUTPUT_DIR/$zstd_name"

    # Skip if already repackaged locally
    if [[ -f "$ZSTD_PATH" ]]; then
        echo "  Already exists locally: $zstd_name"
        SUCCESS=$((SUCCESS + 1))
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Download bz2
    echo "  Downloading..."
    if ! curl -L --progress-bar -o "$BZ2_PATH" "$BZ2_URL"; then
        echo "  Download failed"
        FAILED=$((FAILED + 1))
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
        FAILED=$((FAILED + 1))
        continue
    fi
    rm -f "$BZ2_PATH"  # Free space

    # Recompress with zstd
    echo "  Compressing with zstd (level $ZSTD_LEVEL)..."
    if ! zstd -$ZSTD_LEVEL -T0 --long=31 "$TAR_PATH" -o "$ZSTD_PATH" --quiet; then
        echo "  Zstd compression failed"
        rm -f "$TAR_PATH"
        FAILED=$((FAILED + 1))
        continue
    fi
    rm -f "$TAR_PATH"  # Free space

    ZSTD_SIZE=$(stat -f%z "$ZSTD_PATH" 2>/dev/null || stat -c%s "$ZSTD_PATH")
    TOTAL_ZSTD=$((TOTAL_ZSTD + ZSTD_SIZE))

    if [[ $BZ2_SIZE -gt 0 ]]; then
        SAVINGS=$(( (BZ2_SIZE - ZSTD_SIZE) * 100 / BZ2_SIZE ))
        echo "  Created: $zstd_name (${SAVINGS}% smaller)"
    else
        echo "  Created: $zstd_name"
    fi

    # Generate SHA256
    shasum -a 256 "$ZSTD_PATH" > "${ZSTD_PATH}.sha256"

    SUCCESS=$((SUCCESS + 1))
done

echo ""
echo "================================================"
echo "Summary"
echo "================================================"
echo "Successful: $SUCCESS / $VOICE_COUNT"
echo "Skipped (already local): $SKIPPED"
echo "Failed: $FAILED"
echo ""

# Upload if requested
if $UPLOAD; then
    echo "================================================"
    echo "Uploading to GitHub Release"
    echo "================================================"
    echo "Repo: $GITHUB_REPO"
    echo "Tag:  $RELEASE_TAG"

    echo "Creating/updating release..."
    gh release create "$RELEASE_TAG" \
        --repo "$GITHUB_REPO" \
        --title "Listen2 Voice Models" \
        --notes "Piper TTS voices and grammar packs for Listen2" \
        2>/dev/null || true

    UPLOADED=0
    UPLOAD_SKIPPED=0

    for zst_file in "$OUTPUT_DIR"/vits-piper-${LANG_FILTER}*.tar.zst; do
        [[ -f "$zst_file" ]] || continue
        basename=$(basename "$zst_file")

        # Skip if already on the release
        if echo "$EXISTING_ASSETS" | grep -qF "$basename"; then
            echo "  Already uploaded: $basename"
            UPLOAD_SKIPPED=$((UPLOAD_SKIPPED + 1))
            continue
        fi

        echo "  Uploading: $basename"
        gh release upload "$RELEASE_TAG" "$zst_file" --repo "$GITHUB_REPO" --clobber
        UPLOADED=$((UPLOADED + 1))

        # Also upload SHA256
        if [[ -f "${zst_file}.sha256" ]]; then
            gh release upload "$RELEASE_TAG" "${zst_file}.sha256" --repo "$GITHUB_REPO" --clobber
        fi
    done

    echo ""
    echo "Uploaded: $UPLOADED new files"
    echo "Skipped: $UPLOAD_SKIPPED already on release"
    echo "Release URL: https://github.com/$GITHUB_REPO/releases/tag/$RELEASE_TAG"
fi

echo ""
echo "Done!"
