#!/usr/bin/env python3
"""Generate voice sample MP3s for all Supertonic voices.

Uses the Supertonic ONNX inference pipeline (helper.py) to synthesize
an English rainbow passage for each of the 10 voices, then converts
to MP3 via ffmpeg.

Usage:
    python scripts/generate-supertonic-samples.py
    python scripts/generate-supertonic-samples.py --upload

Requirements:
    pip install onnxruntime numpy soundfile
    ffmpeg must be on PATH

Output:
    repackaged-voices/samples/supertonic-{F1..F5,M1..M5}.mp3
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

# Rainbow passage (same as Piper English sample)
RAINBOW_PASSAGE = (
    "The rainbow is a meteorological phenomenon that is caused by reflection, "
    "refraction and dispersion of light in water droplets resulting in a "
    "spectrum of light appearing in the sky."
)

VOICE_IDS = ["F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"]
VOICE_NAMES = {
    "F1": "Luna", "F2": "Nova", "F3": "Aria", "F4": "Sage", "F5": "Iris",
    "M1": "Atlas", "M2": "Orion", "M3": "Flint", "M4": "Reed", "M5": "Vale",
}

# Synthesis parameters (from design doc)
TOTAL_STEPS = 15      # denoising steps — production robustness
SPEED = 1.05          # slightly faster, maintains clarity
SAMPLE_RATE = 44100   # Supertonic native rate
MP3_BITRATE = "64k"   # consistent with Piper samples
MP3_SAMPLE_RATE = 22050  # downsample for smaller MP3

GITHUB_REPO = "zachswift615/listen-2-assets"
RELEASE_TAG = "voices-v1"


def main():
    parser = argparse.ArgumentParser(description="Generate Supertonic voice samples")
    parser.add_argument(
        "--onnx-dir",
        default=os.path.expanduser("~/projects/supertonic/assets/onnx"),
        help="Path to Supertonic ONNX models",
    )
    parser.add_argument(
        "--styles-dir",
        default=os.path.expanduser("~/projects/supertonic/assets/voice_styles"),
        help="Path to voice style JSON files",
    )
    parser.add_argument(
        "--output-dir",
        default="./repackaged-voices/samples",
        help="Output directory for MP3 files",
    )
    parser.add_argument(
        "--helper",
        default=os.path.expanduser("~/projects/supertonic/py"),
        help="Path to directory containing helper.py",
    )
    parser.add_argument("--upload", action="store_true", help="Upload to GitHub release")
    parser.add_argument("--voice", help="Generate for a single voice (e.g., F1)")
    args = parser.parse_args()

    # Verify ffmpeg
    if not _has_command("ffmpeg"):
        print("Error: ffmpeg not found. Install it first.")
        sys.exit(1)

    # Verify ONNX models
    onnx_dir = Path(args.onnx_dir)
    for model in ["text_encoder.onnx", "duration_predictor.onnx",
                   "vector_estimator.onnx", "vocoder.onnx"]:
        if not (onnx_dir / model).exists():
            print(f"Error: ONNX model not found: {onnx_dir / model}")
            sys.exit(1)

    # Add helper directory to path
    sys.path.insert(0, args.helper)
    try:
        from helper import load_text_to_speech, load_voice_style
    except ImportError:
        print(f"Error: Cannot import helper.py from {args.helper}")
        sys.exit(1)

    # Import soundfile for WAV writing
    try:
        import numpy as np
        import soundfile as sf
    except ImportError:
        print("Error: Install dependencies: pip install numpy soundfile")
        sys.exit(1)

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    styles_dir = Path(args.styles_dir)

    # Determine which voices to generate
    voices = [args.voice] if args.voice else VOICE_IDS

    # Load TTS model once (shared across all voices)
    print("Loading Supertonic TTS model...")
    tts = load_text_to_speech(str(onnx_dir))
    print(f"  Model loaded (sample rate: {SAMPLE_RATE} Hz)")
    print(f"  Text: \"{RAINBOW_PASSAGE[:60]}...\"")
    print(f"  Steps: {TOTAL_STEPS}, Speed: {SPEED}")
    print()

    generated = []
    failed = []

    for voice_id in voices:
        name = VOICE_NAMES.get(voice_id, voice_id)
        style_path = styles_dir / f"{voice_id}.json"

        if not style_path.exists():
            print(f"[skip] {voice_id} ({name}) — style file not found: {style_path}")
            failed.append(voice_id)
            continue

        print(f"[{voice_id}] {name}...", end=" ", flush=True)

        try:
            # Load voice style
            style = load_voice_style([str(style_path)])

            # Synthesize
            wav, dur = tts(
                RAINBOW_PASSAGE,
                lang="en",
                style=style,
                total_step=TOTAL_STEPS,
                speed=SPEED,
            )

            # wav shape: (1, N) — squeeze to 1D
            wav_1d = wav.squeeze()
            duration_s = len(wav_1d) / SAMPLE_RATE

            # Write temporary WAV, convert to MP3
            with tempfile.TemporaryDirectory() as tmp:
                wav_path = Path(tmp) / "sample.wav"
                mp3_path = output_dir / f"supertonic-{voice_id}.mp3"

                sf.write(str(wav_path), wav_1d, SAMPLE_RATE)

                subprocess.run(
                    [
                        "ffmpeg", "-y", "-i", str(wav_path),
                        "-codec:a", "libmp3lame",
                        "-b:a", MP3_BITRATE,
                        "-ar", str(MP3_SAMPLE_RATE),
                        str(mp3_path),
                    ],
                    check=True,
                    capture_output=True,
                )

                size_kb = mp3_path.stat().st_size / 1024
                print(f"OK ({duration_s:.1f}s, {size_kb:.0f} KB)")
                generated.append(voice_id)

        except Exception as e:
            print(f"FAILED: {e}")
            failed.append(voice_id)

    # Summary
    print()
    print(f"=== Done ===")
    print(f"Generated: {len(generated)}/{len(voices)}")
    if failed:
        print(f"Failed: {', '.join(failed)}")

    for vid in generated:
        mp3 = output_dir / f"supertonic-{vid}.mp3"
        print(f"  {mp3}")

    # Upload
    if args.upload and generated:
        print(f"\nUploading to GitHub release ({GITHUB_REPO}, tag {RELEASE_TAG})...")
        files = [str(output_dir / f"supertonic-{vid}.mp3") for vid in generated]
        subprocess.run(
            ["gh", "release", "upload", RELEASE_TAG] + files +
            ["--repo", GITHUB_REPO, "--clobber"],
            check=True,
        )
        print("Upload complete.")


def _has_command(cmd: str) -> bool:
    try:
        subprocess.run([cmd, "-version"], capture_output=True, check=False)
        return True
    except FileNotFoundError:
        return False


if __name__ == "__main__":
    main()
