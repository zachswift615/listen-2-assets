#!/bin/bash
# scripts/package-grammars.sh
# Package NeMo text normalization grammars as .tar.zst for distribution
#
# Usage: ./package-grammars.sh [language|all] [--upload] [--manifest]
#        language: Language code to package (e.g., "es", "de")
#        all: Package all available grammars
#        --upload: Upload to GitHub release
#        --manifest: Generate/update grammar-manifest.json
#
# Examples:
#   ./package-grammars.sh es                    # Package Spanish grammar
#   ./package-grammars.sh all --manifest        # Package all + generate manifest
#   ./package-grammars.sh all --upload --manifest  # Package, manifest, upload

set -e

# Configuration
GRAMMARS_SOURCE="${GRAMMARS_SOURCE:-/Users/zachswift/projects/text-normalizer/nemo-grammars}"
OUTPUT_DIR="${OUTPUT_DIR:-./repackaged-voices}"  # Same dir as voices for unified release
WORK_DIR="${WORK_DIR:-/tmp/grammar-packaging}"
ZSTD_LEVEL=19
GITHUB_REPO="zachswift615/listen-2-assets"
RELEASE_TAG="voices-v1"

# Languages with text normalization grammars
# Note: ar, hy, ja, rw have ITN-only grammars but we still package them
# as the normalizer handles the distinction internally
GRAMMAR_LANGUAGES=(en de es fr it ru ar sv hu zh hy vi rw ja hi)

# Parse arguments
LANG_FILTER=""
UPLOAD=false
GENERATE_MANIFEST=false

for arg in "$@"; do
    case "$arg" in
        --upload) UPLOAD=true ;;
        --manifest) GENERATE_MANIFEST=true ;;
        *) LANG_FILTER="$arg" ;;
    esac
done

if [[ -z "$LANG_FILTER" ]]; then
    echo "Usage: $0 [language|all] [--upload] [--manifest]"
    echo ""
    echo "Available grammar languages:"
    for lang in "${GRAMMAR_LANGUAGES[@]}"; do
        if [[ -d "$GRAMMARS_SOURCE/$lang" ]]; then
            size=$(du -sh "$GRAMMARS_SOURCE/$lang" 2>/dev/null | cut -f1)
            echo "  $lang ($size)"
        else
            echo "  $lang (not found in source)"
        fi
    done
    exit 1
fi

# Build language list
LANGUAGES=()
if [[ "$LANG_FILTER" == "all" ]]; then
    LANGUAGES=("${GRAMMAR_LANGUAGES[@]}")
else
    # Validate language
    VALID=false
    for lang in "${GRAMMAR_LANGUAGES[@]}"; do
        if [[ "$lang" == "$LANG_FILTER" ]]; then
            VALID=true
            break
        fi
    done
    if ! $VALID; then
        echo "Error: Unknown language '$LANG_FILTER'"
        echo "Supported: ${GRAMMAR_LANGUAGES[*]}"
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

# Verify source directory
if [[ ! -d "$GRAMMARS_SOURCE" ]]; then
    echo "Error: Grammar source directory not found: $GRAMMARS_SOURCE"
    echo "Set GRAMMARS_SOURCE env var to override"
    exit 1
fi

# Setup directories
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

echo "================================================"
echo "Packaging ${#LANGUAGES[@]} grammar(s)"
echo "Source: $GRAMMARS_SOURCE"
echo "================================================"
echo ""

SUCCESS=0
FAILED=0

# Manifest data stored in temp file (one "lang sha256 size" per line)
MANIFEST_DATA_FILE="$WORK_DIR/manifest-data.txt"
> "$MANIFEST_DATA_FILE"

for lang in "${LANGUAGES[@]}"; do
    echo "----------------------------------------"
    echo "Processing: $lang"

    LANG_SOURCE="$GRAMMARS_SOURCE/$lang"
    ZSTD_NAME="grammar-${lang}.tar.zst"
    ZSTD_PATH="$OUTPUT_DIR/$ZSTD_NAME"
    TAR_PATH="$WORK_DIR/grammar-${lang}.tar"

    # Verify source exists
    if [[ ! -d "$LANG_SOURCE" ]]; then
        echo "  Source not found: $LANG_SOURCE"
        ((FAILED++))
        continue
    fi

    # Verify key grammar files exist
    if [[ ! -f "$LANG_SOURCE/classify/tokenize_and_classify.fst" ]] && [[ ! -f "$LANG_SOURCE/verbalize/verbalize.fst" ]]; then
        echo "  Warning: Missing expected FST files in $LANG_SOURCE"
        echo "  Packaging anyway (may be ITN-only grammar)"
    fi

    # Create tar archive preserving the language directory structure
    # The tar contains {lang}/ at the top level so FstNormalizer.load() works
    echo "  Creating tar archive..."
    (cd "$GRAMMARS_SOURCE" && tar cf "$TAR_PATH" "$lang/")

    # Compress with zstd
    echo "  Compressing with zstd (level $ZSTD_LEVEL)..."
    if ! zstd -$ZSTD_LEVEL -T0 --long=31 "$TAR_PATH" -o "$ZSTD_PATH" --quiet --force; then
        echo "  Zstd compression failed"
        rm -f "$TAR_PATH"
        ((FAILED++))
        continue
    fi
    rm -f "$TAR_PATH"

    ZSTD_SIZE=$(stat -f%z "$ZSTD_PATH" 2>/dev/null || stat -c%s "$ZSTD_PATH")
    SOURCE_SIZE=$(du -sk "$LANG_SOURCE" | awk '{print $1 * 1024}')
    echo "  Created: $ZSTD_NAME ($(($ZSTD_SIZE/1024)) KB compressed, ${SOURCE_SIZE} bytes uncompressed)"

    # Generate SHA256
    SHA256=$(shasum -a 256 "$ZSTD_PATH" | cut -d' ' -f1)
    echo "$SHA256  $ZSTD_NAME" > "${ZSTD_PATH}.sha256"
    echo "  SHA256: $SHA256"

    # Store for manifest
    echo "$lang $SHA256 $ZSTD_SIZE" >> "$MANIFEST_DATA_FILE"

    ((SUCCESS++))
done

echo ""
echo "================================================"
echo "Summary"
echo "================================================"
echo "Successful: $SUCCESS / ${#LANGUAGES[@]}"
echo "Failed: $FAILED"
echo ""

# Generate manifest
if $GENERATE_MANIFEST; then
    MANIFEST_PATH="$OUTPUT_DIR/grammar-manifest.json"
    echo "Generating grammar manifest..."

    # Build JSON manually (no jq dependency required)
    echo '{' > "$MANIFEST_PATH"
    echo '  "version": 1,' >> "$MANIFEST_PATH"
    echo '  "grammars": {' >> "$MANIFEST_PATH"

    FIRST=true
    sort "$MANIFEST_DATA_FILE" | while IFS=' ' read -r lang sha256 size; do
        if ! $FIRST; then
            echo ',' >> "$MANIFEST_PATH"
        fi
        FIRST=false
        printf '    "%s": { "sha256": "%s", "sizeBytes": %s, "version": "2026.02" }' \
            "$lang" "$sha256" "$size" >> "$MANIFEST_PATH"
    done

    echo '' >> "$MANIFEST_PATH"
    echo '  }' >> "$MANIFEST_PATH"
    echo '}' >> "$MANIFEST_PATH"

    echo "Manifest written to: $MANIFEST_PATH"
    echo ""
fi

rm -f "$MANIFEST_DATA_FILE"

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
        --notes "Piper TTS voices and grammar packs for Listen2" \
        2>/dev/null || true

    # Upload grammar archives
    for lang in "${LANGUAGES[@]}"; do
        ZSTD_PATH="$OUTPUT_DIR/grammar-${lang}.tar.zst"
        if [[ -f "$ZSTD_PATH" ]]; then
            echo "Uploading: grammar-${lang}.tar.zst"
            gh release upload "$RELEASE_TAG" "$ZSTD_PATH" --repo "$GITHUB_REPO" --clobber
        fi
    done

    # Upload manifest if generated
    if $GENERATE_MANIFEST && [[ -f "$OUTPUT_DIR/grammar-manifest.json" ]]; then
        echo "Uploading: grammar-manifest.json"
        gh release upload "$RELEASE_TAG" "$OUTPUT_DIR/grammar-manifest.json" --repo "$GITHUB_REPO" --clobber
    fi

    echo ""
    echo "Upload complete!"
    echo "Release URL: https://github.com/$GITHUB_REPO/releases/tag/$RELEASE_TAG"
fi

echo ""
echo "Done!"
