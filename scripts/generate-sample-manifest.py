#!/usr/bin/env python3
"""Generate sample-manifest.json covering all packaged Piper voices.

Iterates every .tar.zst voice archive, extracts model.onnx.json to read
num_speakers and speaker_id_map, and writes a single JSON manifest.

Usage:
    python scripts/generate-sample-manifest.py
    python scripts/generate-sample-manifest.py --voices-dir ./repackaged-voices
"""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def extract_speaker_info(archive: Path) -> dict | None:
    """Extract num_speakers and speaker_id_map from a voice archive."""
    with tempfile.TemporaryDirectory() as tmp:
        tar_path = f"{tmp}/a.tar"
        subprocess.run(
            ["zstd", "-d", str(archive), "-o", tar_path, "--force", "-q"],
            check=True,
            capture_output=True,
        )
        # Find the .onnx.json inside the tar
        tar_list = subprocess.run(
            ["tar", "tf", tar_path],
            capture_output=True,
            text=True,
            check=True,
        )
        json_file = next(
            (l for l in tar_list.stdout.splitlines() if l.endswith(".onnx.json")),
            None,
        )
        if not json_file:
            return None

        subprocess.run(
            ["tar", "xf", tar_path, "-C", tmp, json_file],
            check=True,
            capture_output=True,
        )
        with open(f"{tmp}/{json_file}") as f:
            data = json.load(f)

        num_speakers = data.get("num_speakers", 1)
        speaker_id_map = data.get("speaker_id_map", {})
        return {"num_speakers": num_speakers, "speaker_id_map": speaker_id_map}


def voice_id_from_archive(archive: Path) -> str:
    """vits-piper-fr_FR-gilles-low.tar.zst -> fr_FR-gilles-low"""
    full = archive.name.replace(".tar.zst", "")  # vits-piper-fr_FR-gilles-low
    return full.removeprefix("vits-piper-")


def main():
    parser = argparse.ArgumentParser(
        description="Generate sample-manifest.json for all Piper voices"
    )
    parser.add_argument(
        "--voices-dir",
        default="./repackaged-voices",
        help="Directory containing voice .tar.zst files",
    )
    parser.add_argument(
        "--output",
        default="./repackaged-voices/sample-manifest.json",
        help="Output manifest path",
    )
    args = parser.parse_args()

    voices_dir = Path(args.voices_dir)
    if not voices_dir.exists():
        print(f"Error: voices directory not found: {voices_dir}", file=sys.stderr)
        sys.exit(1)

    archives = sorted(voices_dir.glob("vits-piper-*.tar.zst"))
    print(f"Found {len(archives)} voice archives")

    manifest = {}
    for archive in archives:
        voice_id = voice_id_from_archive(archive)
        info = extract_speaker_info(archive)
        if info is None:
            print(f"  [skip] {voice_id} (no model JSON)")
            continue

        entry = {"num_speakers": info["num_speakers"]}
        if info["speaker_id_map"]:
            entry["speaker_id_map"] = info["speaker_id_map"]

        manifest[voice_id] = entry
        label = f"{info['num_speakers']} speakers" if info["num_speakers"] > 1 else "single"
        print(f"  {voice_id}: {label}")

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)

    multi = sum(1 for v in manifest.values() if v["num_speakers"] > 1)
    print(f"\nWrote {output_path}: {len(manifest)} voices ({multi} multi-speaker)")


if __name__ == "__main__":
    main()
