#!/bin/bash
# scripts/package-aligner.sh
# Package exported CTC alignment models as .tar.zst for distribution
#
# Usage: ./package-aligner.sh [language|all] [--upload] [--source PATH]
#        language: Language code to package (e.g., "es", "de")
#        all: Package all languages that have an exported model
#        --upload: Upload to GitHub release
#        --source PATH: Override source directory (default: ~/projects/Listen2/scripts/ctc-training/models)
#
# Expected source layout:
#   {source}/{lang}/export/conformer_ctc.mlpackage
#
# The export script in Listen2 produces this layout:
#   python export.py --checkpoint models/{lang}/checkpoints/best.pt \
#                    --output-dir models/{lang}/export --skip-onnx
#
# Examples:
#   ./package-aligner.sh es                    # Package Spanish model
#   ./package-aligner.sh all                   # Package all available
#   ./package-aligner.sh es --upload           # Package + upload Spanish
#   ./package-aligner.sh all --upload          # Package + upload all

set -e

# Configuration
DEFAULT_SOURCE="$HOME/projects/Listen2/scripts/ctc-training/models"
OUTPUT_DIR="${OUTPUT_DIR:-./repackaged-voices}"
WORK_DIR="${WORK_DIR:-/tmp/aligner-packaging}"
ZSTD_LEVEL=19
GITHUB_REPO="zachswift615/listen-2-assets"
RELEASE_TAG="voices-v1"

# All languages that could have alignment models
# English is bundled in the app — it gets uploaded too so the app
# can update it OTA in the future, but it's not required for download.
ALIGNER_LANGUAGES=(en es fr de hu sv ru it vi pt)

# Parse arguments
LANG_FILTER=""
UPLOAD=false
SOURCE_DIR="$DEFAULT_SOURCE"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --upload) UPLOAD=true; shift ;;
        --source) SOURCE_DIR="$2"; shift 2 ;;
        *) LANG_FILTER="$1"; shift ;;
    esac
done

if [[ -z "$LANG_FILTER" ]]; then
    echo "Usage: $0 [language|all] [--upload] [--source PATH]"
    echo ""
    echo "Available languages:"
    for lang in "${ALIGNER_LANGUAGES[@]}"; do
        MLPACKAGE="$SOURCE_DIR/$lang/export/conformer_ctc.mlpackage"
        if [[ -d "$MLPACKAGE" ]]; then
            size=$(du -sh "$MLPACKAGE" 2>/dev/null | cut -f1)
            echo "  $lang ($size) ✓"
        else
            echo "  $lang (no export found)"
        fi
    done
    echo ""
    echo "Source: $SOURCE_DIR"
    echo "Override with: --source /path/to/models"
    exit 1
fi

# Build language list
LANGUAGES=()
if [[ "$LANG_FILTER" == "all" ]]; then
    # Only include languages that have an exported model
    for lang in "${ALIGNER_LANGUAGES[@]}"; do
        if [[ -d "$SOURCE_DIR/$lang/export/conformer_ctc.mlpackage" ]]; then
            LANGUAGES+=("$lang")
        fi
    done
    if [[ ${#LANGUAGES[@]} -eq 0 ]]; then
        echo "Error: No exported models found in $SOURCE_DIR"
        exit 1
    fi
else
    # Validate language
    VALID=false
    for lang in "${ALIGNER_LANGUAGES[@]}"; do
        if [[ "$lang" == "$LANG_FILTER" ]]; then
            VALID=true
            break
        fi
    done
    if ! $VALID; then
        echo "Error: Unknown language '$LANG_FILTER'"
        echo "Supported: ${ALIGNER_LANGUAGES[*]}"
        exit 1
    fi
    LANGUAGES=("$LANG_FILTER")
fi

# Check dependencies
for cmd in zstd tar shasum; do
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
echo "Packaging ${#LANGUAGES[@]} alignment model(s)"
echo "Source: $SOURCE_DIR"
echo "================================================"
echo ""

SUCCESS=0
FAILED=0

for lang in "${LANGUAGES[@]}"; do
    echo "----------------------------------------"
    echo "Processing: $lang"

    MLPACKAGE="$SOURCE_DIR/$lang/export/conformer_ctc.mlpackage"
    ARCHIVE_NAME="aligner-${lang}.mlpackage.tar.zst"
    ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"
    TAR_PATH="$WORK_DIR/aligner-${lang}.mlpackage.tar"

    # Verify source exists
    if [[ ! -d "$MLPACKAGE" ]]; then
        echo "  Export not found: $MLPACKAGE"
        echo "  Run: python export.py --checkpoint models/$lang/checkpoints/best.pt --output-dir models/$lang/export --skip-onnx"
        ((FAILED++))
        continue
    fi

    # Check it looks like a valid mlpackage
    if [[ ! -f "$MLPACKAGE/Manifest.json" ]]; then
        echo "  Warning: $MLPACKAGE missing Manifest.json — may not be a valid mlpackage"
    fi

    # Create tar archive containing conformer_ctc.mlpackage/ at top level
    echo "  Creating tar archive..."
    (cd "$SOURCE_DIR/$lang/export" && tar cf "$TAR_PATH" "conformer_ctc.mlpackage")

    # Compress with zstd
    echo "  Compressing with zstd (level $ZSTD_LEVEL)..."
    if ! zstd -$ZSTD_LEVEL -T0 "$TAR_PATH" -o "$ARCHIVE_PATH" --quiet --force; then
        echo "  Zstd compression failed"
        rm -f "$TAR_PATH"
        ((FAILED++))
        continue
    fi
    rm -f "$TAR_PATH"

    ARCHIVE_SIZE=$(stat -f%z "$ARCHIVE_PATH" 2>/dev/null || stat -c%s "$ARCHIVE_PATH")
    SOURCE_SIZE=$(du -sh "$MLPACKAGE" | cut -f1)
    echo "  Created: $ARCHIVE_NAME ($(($ARCHIVE_SIZE/1024)) KB compressed, $SOURCE_SIZE uncompressed)"

    # Generate SHA256
    SHA256=$(shasum -a 256 "$ARCHIVE_PATH" | cut -d' ' -f1)
    echo "  SHA256: $SHA256"

    ((SUCCESS++))
done

echo ""
echo "================================================"
echo "Summary"
echo "================================================"
echo "Successful: $SUCCESS / ${#LANGUAGES[@]}"
echo "Failed: $FAILED"

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
        --notes "Piper TTS voices, grammar packs, and alignment models for Listen2" \
        2>/dev/null || true

    for lang in "${LANGUAGES[@]}"; do
        ARCHIVE_PATH="$OUTPUT_DIR/aligner-${lang}.mlpackage.tar.zst"
        if [[ -f "$ARCHIVE_PATH" ]]; then
            echo "Uploading: aligner-${lang}.mlpackage.tar.zst"
            gh release upload "$RELEASE_TAG" "$ARCHIVE_PATH" --repo "$GITHUB_REPO" --clobber
        fi
    done

    echo ""
    echo "Upload complete!"
    echo "Release URL: https://github.com/$GITHUB_REPO/releases/tag/$RELEASE_TAG"
fi

echo ""
echo "Done!"
