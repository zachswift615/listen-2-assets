#!/usr/bin/env python3
"""
Generate supertonic-manifest.json for Supertonic TTS engine discovery.

Usage:
    python scripts/generate-supertonic-manifest.py [--upload]

Reads SHA256 from repackaged-voices/supertonic-engine-v1.tar.zst.sha256
Outputs repackaged-voices/supertonic-manifest.json

The manifest is consumed by the Listen2 app to discover Supertonic voices
and know where to download the shared engine archive.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

# Voice catalog — confirmed names
VOICES = [
    {"id": "supertonic-F1", "name": "Luna",   "gender": "female"},
    {"id": "supertonic-F2", "name": "Nova",   "gender": "female"},
    {"id": "supertonic-F3", "name": "Aria",   "gender": "female"},
    {"id": "supertonic-F4", "name": "Sage",   "gender": "female"},
    {"id": "supertonic-F5", "name": "Iris",   "gender": "female"},
    {"id": "supertonic-M1", "name": "Atlas",  "gender": "male"},
    {"id": "supertonic-M2", "name": "Orion",  "gender": "male"},
    {"id": "supertonic-M3", "name": "Flint",  "gender": "male"},
    {"id": "supertonic-M4", "name": "Reed",   "gender": "male"},
    {"id": "supertonic-M5", "name": "Vale",   "gender": "male"},
]

# All Supertonic voices support these languages
LANGUAGES = ["en", "es", "fr", "ko", "pt"]

GITHUB_REPO = "zachswift615/listen-2-assets"
RELEASE_TAG = "voices-v1"
ARCHIVE_NAME = "supertonic-engine-v1"
SAMPLE_BASE_URL = "https://moonquakemedia.com/assets/listen2/samples"


def main():
    parser = argparse.ArgumentParser(description="Generate Supertonic manifest")
    parser.add_argument("--upload", action="store_true", help="Upload manifest to GitHub release")
    parser.add_argument("--output-dir", default="./repackaged-voices", help="Output directory")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)

    # Read SHA256 from packaging output
    sha256_path = output_dir / f"{ARCHIVE_NAME}.tar.zst.sha256"
    if not sha256_path.exists():
        print(f"Error: SHA256 file not found: {sha256_path}")
        print(f"Run package-supertonic-engine.sh first.")
        sys.exit(1)

    sha256 = sha256_path.read_text().strip().split()[0]

    # Get archive size
    archive_path = output_dir / f"{ARCHIVE_NAME}.tar.zst"
    if archive_path.exists():
        size_mb = round(archive_path.stat().st_size / (1024 * 1024))
    else:
        size_mb = 132  # fallback estimate

    # Build manifest
    download_url = (
        f"https://github.com/{GITHUB_REPO}/releases/download/"
        f"{RELEASE_TAG}/{ARCHIVE_NAME}.tar.zst"
    )

    manifest = {
        "engine": "supertonic",
        "engineVersion": "1.0",
        "engineDownloadURL": download_url,
        "engineSizeMB": size_mb,
        "engineSHA256": sha256,
        "sampleRate": 44100,
        "sampleBaseURL": SAMPLE_BASE_URL,
        "voices": [
            {
                "id": v["id"],
                "name": v["name"],
                "gender": v["gender"],
                "languages": LANGUAGES,
            }
            for v in VOICES
        ],
    }

    # Write manifest
    manifest_path = output_dir / "supertonic-manifest.json"
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")

    print(f"Generated: {manifest_path}")
    print(f"  Engine:  {download_url}")
    print(f"  Size:    {size_mb} MB")
    print(f"  SHA256:  {sha256}")
    print(f"  Voices:  {len(VOICES)}")
    print(f"  Sample:  {SAMPLE_BASE_URL}/supertonic-{{id}}.mp3")

    # Upload
    if args.upload:
        print(f"\nUploading to GitHub release ({GITHUB_REPO}, tag {RELEASE_TAG})...")
        subprocess.run(
            [
                "gh", "release", "upload", RELEASE_TAG,
                str(manifest_path),
                "--repo", GITHUB_REPO,
                "--clobber",
            ],
            check=True,
        )
        print("Upload complete.")


if __name__ == "__main__":
    main()
