#!/usr/bin/env python3
"""Generate voice sample MP3s for all Supertonic voices.

Uses the Supertonic ONNX inference pipeline (helper.py) to synthesize
sample passages for each of the 10 voices in each enabled language,
then converts to MP3 via ffmpeg.

Usage:
    python scripts/generate-supertonic-samples.py
    python scripts/generate-supertonic-samples.py --lang es fr
    python scripts/generate-supertonic-samples.py --upload

Requirements:
    pip install onnxruntime numpy soundfile
    ffmpeg must be on PATH

Output:
    English:  supertonic-{F1..M5}.mp3
    Spanish:  supertonic-{F1..M5}_es.mp3
    French:   supertonic-{F1..M5}_fr.mp3
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

# Per-language sample texts. Rainbow-themed descriptions for consistency across
# voices and languages. Lengths roughly equivalent so duration comparisons make
# sense. Codes match SupertonicTTSProvider.supportedManifestLanguages.
SAMPLE_TEXTS = {
    "en": (
        "The rainbow is a meteorological phenomenon that is caused by reflection, "
        "refraction and dispersion of light in water droplets resulting in a "
        "spectrum of light appearing in the sky."
    ),
    "es": (
        "El arcoíris es un fenómeno óptico y meteorológico que consiste en la "
        "aparición en el cielo de un arco de luz multicolor, originado por la "
        "descomposición de la luz solar en el espectro visible."
    ),
    "it": (
        "L'arcobaleno è un fenomeno ottico e meteorologico che produce uno spettro "
        "quasi continuo di luce nel cielo quando la luce del sole attraversa le "
        "gocce d'acqua rimaste in sospensione dopo un temporale."
    ),
    "fr": (
        "Un arc-en-ciel est un photométéore, un phénomène optique se produisant "
        "dans le ciel, visible dans la direction opposée au Soleil quand il brille "
        "pendant la pluie. C'est un arc de cercle coloré d'un dégradé de couleurs."
    ),
    "de": (
        "Ein Regenbogen ist ein atmosphärisch-optisches Phänomen, das als "
        "kreisbogenförmiges farbiges Lichtband in einer von der Sonne beschienenen "
        "Regenwand oder Regenwolke wahrgenommen wird."
    ),
    "sv": (
        "En regnbåge är ett optiskt fenomen som består av en synlig båge med "
        "spektrums alla färger på himlen när det regnar och solen skiner "
        "samtidigt från motsatt håll."
    ),
    "el": (
        "Το ουράνιο τόξο είναι ένα οπτικό και μετεωρολογικό φαινόμενο που "
        "προκαλείται από την ανάκλαση, τη διάθλαση και τη διασπορά του φωτός "
        "σε σταγονίδια νερού."
    ),
    "vi": (
        "Cầu vồng là hiện tượng quang học và khí tượng tạo ra dải quang phổ "
        "liên tục các màu sắc trên bầu trời khi ánh sáng Mặt Trời đi qua "
        "những giọt nước trong không khí sau cơn mưa."
    ),
    "ru": (
        "Радуга — это атмосферное оптическое явление, наблюдаемое при освещении "
        "ярким источником света множества водяных капель, представляющее собой "
        "разноцветную дугу на небосводе."
    ),
    "tr": (
        "Gökkuşağı, yağmur damlalarında güneş ışınlarının kırılması, yansıması "
        "ve dağılması sonucu oluşan, gökyüzünde renkli bir kavis biçiminde "
        "görünen optik ve meteorolojik bir olaydır."
    ),
    "pt": (
        "O arco-íris é um fenômeno óptico e meteorológico que separa a luz do sol "
        "em seu espectro contínuo quando esta atravessa as gotas de água que "
        "ficam suspensas na atmosfera."
    ),
    "hi": (
        "इंद्रधनुष एक प्रकाशीय और मौसम संबंधी घटना है, जिसमें जल की बूंदों में सूर्य के "
        "प्रकाश के परावर्तन, अपवर्तन और परिक्षेपण से आकाश में रंगीन चाप दिखाई देता है।"
    ),
    "hu": (
        "A szivárvány optikai és meteorológiai jelenség, amely a légkörben lévő "
        "esőcseppeken áthaladó napfény visszaverődése, törése és színekre "
        "bontása révén keletkezik az égbolton."
    ),
}

ALL_LANGUAGES = list(SAMPLE_TEXTS.keys())

VOICE_IDS = ["F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"]
VOICE_NAMES = {
    "F1": "Luna", "F2": "Nova", "F3": "Aria", "F4": "Sage", "F5": "Iris",
    "M1": "Atlas", "M2": "Orion", "M3": "Flint", "M4": "Reed", "M5": "Vale",
}

# Synthesis parameters
TOTAL_STEPS = 12      # v3 default — was 15 for v2 robustness, v3 model is more robust
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
        default=os.path.expanduser("~/projects/supertonic/assets-v3/onnx"),
        help="Path to Supertonic ONNX models",
    )
    parser.add_argument(
        "--styles-dir",
        default=os.path.expanduser("~/projects/supertonic/assets-v3/voice_styles"),
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
    parser.add_argument(
        "--lang", nargs="*", default=None,
        help="Languages to generate (e.g., --lang es fr). Default: all languages.",
    )
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

    # Determine which voices and languages to generate
    voices = [args.voice] if args.voice else VOICE_IDS
    languages = args.lang if args.lang else ALL_LANGUAGES

    # Validate language codes
    for lang in languages:
        if lang not in SAMPLE_TEXTS:
            print(f"Error: Unknown language '{lang}'. Available: {', '.join(ALL_LANGUAGES)}")
            sys.exit(1)

    # Load TTS model once (shared across all voices)
    print("Loading Supertonic TTS model...")
    tts = load_text_to_speech(str(onnx_dir))
    print(f"  Model loaded (sample rate: {SAMPLE_RATE} Hz)")
    print(f"  Languages: {', '.join(languages)}")
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

        # Load voice style once per voice (shared across languages)
        style = load_voice_style([str(style_path)])

        for lang in languages:
            text = SAMPLE_TEXTS[lang]
            # English uses base name (backward-compatible), others get _lang suffix
            if lang == "en":
                mp3_name = f"supertonic-{voice_id}.mp3"
            else:
                mp3_name = f"supertonic-{voice_id}_{lang}.mp3"

            label = f"{voice_id}/{lang}"
            print(f"[{label}] {name}...", end=" ", flush=True)

            try:
                wav, dur = tts(
                    text,
                    lang=lang,
                    style=style,
                    total_step=TOTAL_STEPS,
                    speed=SPEED,
                )

                wav_1d = wav.squeeze()
                duration_s = len(wav_1d) / SAMPLE_RATE

                with tempfile.TemporaryDirectory() as tmp:
                    wav_path = Path(tmp) / "sample.wav"
                    mp3_path = output_dir / mp3_name

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
                    generated.append(mp3_name)

            except Exception as e:
                print(f"FAILED: {e}")
                failed.append(label)

    # Summary
    print()
    print(f"=== Done ===")
    print(f"Generated: {len(generated)}/{len(voices) * len(languages)}")
    if failed:
        print(f"Failed: {', '.join(failed)}")

    for name in generated:
        print(f"  {output_dir / name}")

    # Upload
    if args.upload and generated:
        print(f"\nUploading to GitHub release ({GITHUB_REPO}, tag {RELEASE_TAG})...")
        files = [str(output_dir / name) for name in generated]
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
