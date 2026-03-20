#!/usr/bin/env python3
"""Generate voice sample MP3s for Kokoro voices.

Uses the kokoro Python package to synthesize sample passages for each
voice in each v1 language, then converts to MP3 via ffmpeg.

Usage:
    python scripts/generate-kokoro-samples.py
    python scripts/generate-kokoro-samples.py --upload
    python scripts/generate-kokoro-samples.py --voice af_heart

Requirements:
    pip install kokoro soundfile
    ffmpeg must be on PATH

Output:
    kokoro-{voice_id}.mp3  (e.g., kokoro-af_heart.mp3)
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

# Per-language sample texts (rainbow passage variants)
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
    "fr": (
        "Un arc-en-ciel est un photométéore, un phénomène optique se produisant "
        "dans le ciel, visible dans la direction opposée au Soleil quand il brille "
        "pendant la pluie. C'est un arc de cercle coloré d'un dégradé de couleurs."
    ),
    "hi": (
        "इंद्रधनुष एक प्राकृतिक घटना है जो वर्षा की बूंदों में प्रकाश के "
        "परावर्तन, अपवर्तन और विक्षेपण के कारण आकाश में दिखाई देती है।"
    ),
    "it": (
        "L'arcobaleno è un fenomeno ottico e meteorologico che produce uno spettro "
        "quasi continuo di luce nel cielo quando la luce del sole viene rifratta "
        "dalle gocce d'acqua rimaste in sospensione dopo un temporale."
    ),
    "pt": (
        "O arco-íris é um fenómeno óptico e meteorológico que separa a luz do sol "
        "em seu espectro contínuo quando o sol brilha sobre gotas de chuva."
    ),
}

# v1 voice IDs grouped by language prefix
V1_VOICES = {
    "en": [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica",
        "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam",
        "am_michael", "am_onyx", "am_puck", "am_santa",
    ],
    "es": ["ef_dora", "em_alex", "em_santa"],
    "fr": ["ff_siwis"],
    "hi": ["hf_alpha", "hf_beta", "hm_omega", "hm_psi"],
    "it": ["if_sara", "im_nicola"],
    "pt": ["pf_dora", "pm_alex", "pm_santa"],
}

SAMPLE_RATE = 24000
MP3_BITRATE = "64k"
MP3_SAMPLE_RATE = 22050

UPLOAD_DIR = os.path.expanduser(
    "~/projects/moonquakemedia-site/src/assets/listen2/samples"
)


def main():
    parser = argparse.ArgumentParser(description="Generate Kokoro voice samples")
    parser.add_argument(
        "--output-dir",
        default="./repackaged-voices/kokoro-samples",
        help="Output directory for MP3 files",
    )
    parser.add_argument("--upload", action="store_true",
                        help="Copy MP3s to moonquakemedia-site samples dir")
    parser.add_argument("--voice", help="Generate for a single voice (e.g., af_heart)")
    parser.add_argument("--lang", nargs="*", default=None,
                        help="Languages to generate (e.g., --lang es fr)")
    args = parser.parse_args()

    if not _has_command("ffmpeg"):
        print("Error: ffmpeg not found. Install it first.")
        sys.exit(1)

    try:
        from kokoro import KPipeline
    except ImportError:
        print("Error: Install kokoro: pip install kokoro")
        print("  Or use: pip install kokoro soundfile")
        sys.exit(1)

    try:
        import soundfile as sf
    except ImportError:
        print("Error: Install soundfile: pip install soundfile")
        sys.exit(1)

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Determine which languages/voices to process
    if args.voice:
        # Single voice mode
        lang = _voice_to_lang(args.voice)
        voices_to_process = [(lang, args.voice)]
    elif args.lang:
        voices_to_process = []
        for lang in args.lang:
            if lang in V1_VOICES:
                for v in V1_VOICES[lang]:
                    voices_to_process.append((lang, v))
            else:
                print(f"Warning: No voices defined for language '{lang}'")
    else:
        voices_to_process = []
        for lang, voice_list in V1_VOICES.items():
            for v in voice_list:
                voices_to_process.append((lang, v))

    total = len(voices_to_process)
    print(f"Generating {total} voice samples...")

    # Group by language to reuse pipeline
    by_lang = {}
    for lang, voice in voices_to_process:
        by_lang.setdefault(lang, []).append(voice)

    generated = []
    for lang, voice_list in by_lang.items():
        kokoro_lang = _lang_to_kokoro_lang(lang)
        print(f"\nInitializing Kokoro pipeline for {lang} ({kokoro_lang})...")
        pipeline = KPipeline(lang_code=kokoro_lang)

        sample_text = SAMPLE_TEXTS.get(lang, SAMPLE_TEXTS["en"])

        for voice_id in voice_list:
            mp3_name = f"kokoro-{voice_id}.mp3"
            mp3_path = output_dir / mp3_name
            print(f"  {voice_id} -> {mp3_name}...", end=" ", flush=True)

            try:
                # Synthesize
                generator = pipeline(sample_text, voice=voice_id, speed=1.0)
                all_audio = []
                for _gs, _ps, audio in generator:
                    all_audio.append(audio)

                import numpy as np
                combined = np.concatenate(all_audio)

                # Write WAV to temp file
                with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                    sf.write(tmp.name, combined, SAMPLE_RATE)
                    wav_path = tmp.name

                # Convert to MP3
                subprocess.run(
                    ["ffmpeg", "-y", "-i", wav_path, "-ar", str(MP3_SAMPLE_RATE),
                     "-b:a", MP3_BITRATE, "-ac", "1", str(mp3_path)],
                    capture_output=True, check=True,
                )
                os.unlink(wav_path)

                size_kb = mp3_path.stat().st_size // 1024
                print(f"OK ({size_kb} KB)")
                generated.append(mp3_path)

            except Exception as e:
                print(f"FAILED: {e}")

    print(f"\n=== Generated {len(generated)}/{total} samples ===")

    if args.upload and generated:
        upload_dir = Path(UPLOAD_DIR)
        if not upload_dir.exists():
            print(f"Error: Upload directory not found: {upload_dir}")
            sys.exit(1)

        print(f"\nCopying to {upload_dir}...")
        import shutil
        for mp3_path in generated:
            dest = upload_dir / mp3_path.name
            shutil.copy2(mp3_path, dest)
            print(f"  {mp3_path.name}")

        print(f"\nDone. Remember to commit and push moonquakemedia-site.")


def _voice_to_lang(voice_id: str) -> str:
    prefix = voice_id[0] if voice_id else "a"
    return {
        "a": "en", "b": "en", "e": "es", "f": "fr",
        "h": "hi", "i": "it", "j": "ja", "p": "pt", "z": "zh",
    }.get(prefix, "en")


def _lang_to_kokoro_lang(lang: str) -> str:
    return {
        "en": "a",  # American English
        "es": "e",
        "fr": "f",
        "hi": "h",
        "it": "i",
        "ja": "j",
        "pt": "p",
        "zh": "z",
    }.get(lang, "a")


def _has_command(cmd: str) -> bool:
    return subprocess.run(
        ["which", cmd], capture_output=True
    ).returncode == 0


if __name__ == "__main__":
    main()
