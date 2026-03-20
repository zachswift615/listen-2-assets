#!/bin/bash
# scripts/package-kokoro-engine.sh
# Package Kokoro CoreML models + G2P + lexicon + voices as .tar.zst for distribution
#
# Usage: ./package-kokoro-engine.sh [--upload] [--download]
#        --download: Download models from HuggingFace first
#        --upload: Upload to GitHub release after packaging
#
# Output:
#   repackaged-voices/kokoro-engine-v1.tar.zst       (~1 GB estimated)
#   repackaged-voices/kokoro-engine-v1.tar.zst.sha256
#
# The archive contains:
#   kokoro-engine-v1/
#   ├── kokoro_21_15s.mlmodelc/     # Main TTS model (15s variant)
#   ├── G2PEncoder.mlmodelc/        # English G2P encoder (BART)
#   ├── G2PDecoder.mlmodelc/        # English G2P decoder (BART)
#   ├── MultilingualG2PEncoder.mlmodelc/  # Multilingual G2P (ByT5)
#   ├── MultilingualG2PDecoder.mlmodelc/  # Multilingual G2P (ByT5)
#   ├── config.json
#   ├── g2p_vocab.json
#   ├── vocab_index.json
#   ├── us_gold.json
#   ├── us_silver.json
#   ├── us_lexicon_cache.json
#   └── voices/                     # Voice embedding JSONs
#       ├── af_heart.json ... (v1 languages: EN, ES, FR, HI, IT, PT)
#
# On --upload, the script also:
#   1. Computes SHA256 of the archive
#   2. Bumps manifestVersion in kokoro-manifest.json
#   3. Updates engineSHA256 and engineSizeMB in the manifest
#   4. Uploads archive + manifest to the GitHub release

set -e

# Configuration
HF_REPO="FluidInference/kokoro-82m-coreml"
OUTPUT_DIR="${OUTPUT_DIR:-./repackaged-voices}"
WORK_DIR="/tmp/kokoro-packaging"
DOWNLOAD_DIR="/tmp/kokoro-hf-download"
ARCHIVE_NAME="kokoro-engine-v1"
MANIFEST="$OUTPUT_DIR/kokoro-manifest.json"
ZSTD_LEVEL=19
GITHUB_REPO="zachswift615/listen-2-assets"
RELEASE_TAG="voices-v1"

# Models to include (compiled .mlmodelc only)
MODELS=(
    kokoro_21_15s.mlmodelc
    G2PEncoder.mlmodelc
    G2PDecoder.mlmodelc
    MultilingualG2PEncoder.mlmodelc
    MultilingualG2PDecoder.mlmodelc
)

# Top-level config/lexicon files
CONFIG_FILES=(
    config.json
    g2p_vocab.json
    vocab_index.json
    us_gold.json
    us_silver.json
    us_lexicon_cache.json
)

# v1 voice prefixes (EN, ES, FR, HI, IT, PT)
# Excludes: bf_/bm_ (British), jf_/jm_ (Japanese), zf_/zm_ (Chinese)
V1_VOICE_PREFIXES="af_ am_ ef_ em_ ff_ hf_ hm_ if_ im_ pf_ pm_"

# Parse arguments
UPLOAD=false
DOWNLOAD=false
for arg in "$@"; do
    case "$arg" in
        --upload) UPLOAD=true ;;
        --download) DOWNLOAD=true ;;
        -h|--help)
            echo "Usage: $0 [--download] [--upload]"
            echo "  --download  Download models from HuggingFace ($HF_REPO)"
            echo "  --upload    Upload archive + manifest to GitHub release ($GITHUB_REPO, tag $RELEASE_TAG)"
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

# Download from HuggingFace if requested
if $DOWNLOAD; then
    echo "=== Downloading from HuggingFace: $HF_REPO ==="
    mkdir -p "$DOWNLOAD_DIR"

    python3 -c "
from huggingface_hub import snapshot_download
import sys

# Download only compiled models (.mlmodelc), config files, and voice embeddings
snapshot_download(
    repo_id='$HF_REPO',
    local_dir='$DOWNLOAD_DIR',
    allow_patterns=[
        '*.mlmodelc/**',
        'config.json',
        'g2p_vocab.json',
        'vocab_index.json',
        'us_gold.json',
        'us_silver.json',
        'us_lexicon_cache.json',
        'voices/*.json',
    ],
    ignore_patterns=[
        '*.mlpackage/**',
        'README.md',
        '.gitattributes',
        'gb_gold.json',
        'gb_silver.json',
    ],
)
print('Download complete.')
"
    echo ""
fi

# Determine source directory
if [[ -d "$DOWNLOAD_DIR/kokoro_21_15s.mlmodelc" ]]; then
    SOURCE_DIR="$DOWNLOAD_DIR"
elif [[ -d "$HOME/.cache/fluidaudio/Models/kokoro/kokoro_21_15s.mlmodelc" ]]; then
    SOURCE_DIR="$HOME/.cache/fluidaudio/Models/kokoro"
else
    echo "Error: Kokoro models not found."
    echo "Run with --download to fetch from HuggingFace, or ensure they exist at:"
    echo "  $DOWNLOAD_DIR/kokoro_21_15s.mlmodelc"
    echo "  $HOME/.cache/fluidaudio/Models/kokoro/kokoro_21_15s.mlmodelc"
    exit 1
fi

echo "=== Packaging Kokoro Engine ==="
echo "Source: $SOURCE_DIR"
echo "Output: $OUTPUT_DIR/$ARCHIVE_NAME.tar.zst"
echo ""

# Verify models exist
for model in "${MODELS[@]}"; do
    if [[ ! -d "$SOURCE_DIR/$model" ]]; then
        echo "Error: Model not found: $SOURCE_DIR/$model"
        exit 1
    fi
done

# Clean work directory
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/$ARCHIVE_NAME/voices"
mkdir -p "$OUTPUT_DIR"

# Copy CoreML models
echo "Copying CoreML models..."
for model in "${MODELS[@]}"; do
    echo "  $model"
    cp -r "$SOURCE_DIR/$model" "$WORK_DIR/$ARCHIVE_NAME/"
done

# Copy config/lexicon files
echo "Copying config and lexicon files..."
for file in "${CONFIG_FILES[@]}"; do
    if [[ -f "$SOURCE_DIR/$file" ]]; then
        echo "  $file"
        cp "$SOURCE_DIR/$file" "$WORK_DIR/$ARCHIVE_NAME/"
    else
        echo "  Warning: $file not found, skipping"
    fi
done

# Copy v1 voice embeddings
echo "Copying v1 voice embeddings..."
VOICE_COUNT=0
for prefix in $V1_VOICE_PREFIXES; do
    for voice_file in "$SOURCE_DIR/voices/${prefix}"*.json; do
        if [[ -f "$voice_file" ]]; then
            voice_name=$(basename "$voice_file")
            echo "  $voice_name"
            cp "$voice_file" "$WORK_DIR/$ARCHIVE_NAME/voices/"
            VOICE_COUNT=$((VOICE_COUNT + 1))
        fi
    done
done
echo "  ($VOICE_COUNT voices copied)"

# Show sizes
echo ""
echo "Uncompressed sizes:"
du -sh "$WORK_DIR/$ARCHIVE_NAME"
for model in "${MODELS[@]}"; do
    du -sh "$WORK_DIR/$ARCHIVE_NAME/$model"
done
du -sh "$WORK_DIR/$ARCHIVE_NAME/voices"

# Create tar archive
echo ""
echo "Creating tar archive..."
tar cf "$WORK_DIR/$ARCHIVE_NAME.tar" -C "$WORK_DIR" "$ARCHIVE_NAME/"

# Compress with zstd
echo "Compressing with zstd (level $ZSTD_LEVEL)... (this may take a few minutes)"
zstd -"$ZSTD_LEVEL" -T0 --long=31 "$WORK_DIR/$ARCHIVE_NAME.tar" -o "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" --force

# Generate SHA256
echo "Generating SHA256 checksum..."
SHA256=$(shasum -a 256 "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" | cut -d' ' -f1)
echo "$SHA256  $OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" > "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst.sha256"

# Get compressed size
COMPRESSED_SIZE=$(du -sh "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" | cut -f1)
COMPRESSED_BYTES=$(stat -f%z "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" 2>/dev/null || stat -c%s "$OUTPUT_DIR/$ARCHIVE_NAME.tar.zst" 2>/dev/null)
SIZE_MB=$(( (COMPRESSED_BYTES + 1048575) / 1048576 ))

# Report
echo ""
echo "=== Done ==="
echo "Archive:  $OUTPUT_DIR/$ARCHIVE_NAME.tar.zst ($COMPRESSED_SIZE)"
echo "SHA256:   $SHA256"
echo "Size MB:  $SIZE_MB"
echo "Voices:   $VOICE_COUNT"
echo "Checksum: $OUTPUT_DIR/$ARCHIVE_NAME.tar.zst.sha256"

# Update manifest and upload
if $UPLOAD; then
    echo ""

    # Create manifest if it doesn't exist
    if [[ ! -f "$MANIFEST" ]]; then
        echo "Creating initial kokoro-manifest.json..."
        cat > "$MANIFEST" <<MANIFEST_EOF
{
  "engine": "kokoro",
  "engineVersion": "1.0",
  "manifestVersion": 0,
  "engineDownloadURL": "https://github.com/$GITHUB_REPO/releases/download/$RELEASE_TAG/$ARCHIVE_NAME.tar.zst",
  "engineSizeMB": $SIZE_MB,
  "engineSHA256": "$SHA256",
  "sampleBaseURL": "https://moonquakemedia.com/assets/listen2/samples",
  "minimumRAMGB": 8,
  "voices": []
}
MANIFEST_EOF
    fi

    # Build voice list from packaged voice files
    VOICE_JSON="["
    FIRST=true
    for voice_file in "$WORK_DIR/$ARCHIVE_NAME/voices/"*.json; do
        voice_name=$(basename "$voice_file" .json)

        # Determine language and gender from prefix
        prefix="${voice_name:0:2}"
        case "${prefix:0:1}" in
            a) lang="en"; locale="en_US" ;;
            b) lang="en"; locale="en_GB" ;;
            e) lang="es"; locale="es_ES" ;;
            f) lang="fr"; locale="fr_FR" ;;
            h) lang="hi"; locale="hi_IN" ;;
            i) lang="it"; locale="it_IT" ;;
            j) lang="ja"; locale="ja_JP" ;;
            p) lang="pt"; locale="pt_BR" ;;
            z) lang="zh"; locale="zh_CN" ;;
            *) lang="en"; locale="en_US" ;;
        esac

        case "${prefix:1:1}" in
            f) gender="female" ;;
            m) gender="male" ;;
            *) gender="neutral" ;;
        esac

        # Extract display name from voice ID (after underscore)
        display_name="${voice_name#*_}"
        # Capitalize first letter
        display_name="$(echo "${display_name:0:1}" | tr '[:lower:]' '[:upper:]')${display_name:1}"

        if ! $FIRST; then VOICE_JSON+=","; fi
        FIRST=false
        VOICE_JSON+="
    {\"id\": \"$voice_name\", \"name\": \"$display_name\", \"gender\": \"$gender\", \"locale\": \"$locale\", \"languages\": [\"$lang\"]}"
    done
    VOICE_JSON+="
  ]"

    # Read current manifest version, bump it
    OLD_VERSION=$(jq '.manifestVersion // 0' "$MANIFEST")
    NEW_VERSION=$((OLD_VERSION + 1))

    # Update manifest with new SHA, size, version, and voice list
    jq --arg sha "$SHA256" \
       --argjson size "$SIZE_MB" \
       --argjson ver "$NEW_VERSION" \
       --argjson voices "$VOICE_JSON" \
       '.engineSHA256 = $sha | .engineSizeMB = $size | .manifestVersion = $ver | .voices = $voices' \
       "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"

    echo "Updated manifest:"
    echo "  manifestVersion: $OLD_VERSION -> $NEW_VERSION"
    echo "  engineSHA256:    $SHA256"
    echo "  engineSizeMB:    $SIZE_MB"
    echo "  voices:          $VOICE_COUNT"
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
