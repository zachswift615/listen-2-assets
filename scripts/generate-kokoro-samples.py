#!/usr/bin/env python3
"""Generate voice sample MP3s for Kokoro voices.

Uses sherpa-onnx Python bindings with the Kokoro multi-lang model to
synthesize sample passages for each voice, then converts to MP3 via ffmpeg.

Usage:
    python scripts/generate-kokoro-samples.py
    python scripts/generate-kokoro-samples.py --upload
    python scripts/generate-kokoro-samples.py --voice af_heart
    python scripts/generate-kokoro-samples.py --lang es fr hi it pt

Requirements:
    pip install sherpa-onnx numpy
    ffmpeg must be on PATH
    Kokoro model at MODEL_DIR (downloaded from sherpa-onnx releases)

Output:
    kokoro-{voice_id}.mp3  (e.g., kokoro-af_heart.mp3)
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

# Default model directory — download from:
# gh release download tts-models --repo k2-fsa/sherpa-onnx -p "kokoro-multi-lang-v1_0.tar.bz2"
MODEL_DIR = os.environ.get(
    "KOKORO_MODEL_DIR",
    "/tmp/kokoro-model/kokoro-multi-lang-v1_0",
)

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

# Voice IDs grouped by language, with speaker indices matching voices.bin
# Must match KokoroTTSProvider.speaker2id in the iOS app
VOICES = {
    "en": [
        ("af_alloy", 0), ("af_aoede", 1), ("af_bella", 2), ("af_heart", 3),
        ("af_jessica", 4), ("af_kore", 5), ("af_nicole", 6), ("af_nova", 7),
        ("af_river", 8), ("af_sarah", 9), ("af_sky", 10),
        ("am_adam", 11), ("am_echo", 12), ("am_eric", 13), ("am_fenrir", 14),
        ("am_liam", 15), ("am_michael", 16), ("am_onyx", 17), ("am_puck", 18),
        ("am_santa", 19),
        ("bf_alice", 20), ("bf_emma", 21), ("bf_isabella", 22), ("bf_lily", 23),
        ("bm_daniel", 24), ("bm_fable", 25), ("bm_george", 26), ("bm_lewis", 27),
    ],
    "es": [("ef_dora", 28), ("em_alex", 29)],
    "fr": [("ff_siwis", 30)],
    "hi": [("hf_alpha", 31), ("hf_beta", 32), ("hm_omega", 33), ("hm_psi", 34)],
    "it": [("if_sara", 35), ("im_nicola", 36)],
    "pt": [("pf_dora", 42), ("pm_alex", 43), ("pm_santa", 44)],
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
    parser.add_argument("--model-dir", default=MODEL_DIR,
                        help="Path to extracted kokoro-multi-lang model")
    args = parser.parse_args()

    if not _has_command("ffmpeg"):
        print("Error: ffmpeg not found. Install it first.")
        sys.exit(1)

    model_dir = Path(args.model_dir)
    if not (model_dir / "model.onnx").exists():
        print(f"Error: Model not found at {model_dir}")
        print("Download it:")
        print("  gh release download tts-models --repo k2-fsa/sherpa-onnx -p 'kokoro-multi-lang-v1_0.tar.bz2'")
        print("  tar xjf kokoro-multi-lang-v1_0.tar.bz2")
        sys.exit(1)

    try:
        import sherpa_onnx
    except ImportError:
        print("Error: Install sherpa-onnx: pip install sherpa-onnx")
        sys.exit(1)

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Determine which languages/voices to process
    if args.voice:
        lang = _voice_to_lang(args.voice)
        sid = _voice_to_sid(args.voice)
        voices_to_process = [(lang, args.voice, sid)]
    elif args.lang:
        voices_to_process = []
        for lang in args.lang:
            if lang in VOICES:
                for voice_id, sid in VOICES[lang]:
                    voices_to_process.append((lang, voice_id, sid))
            else:
                print(f"Warning: No voices defined for language '{lang}'")
    else:
        voices_to_process = []
        for lang, voice_list in VOICES.items():
            for voice_id, sid in voice_list:
                voices_to_process.append((lang, voice_id, sid))

    total = len(voices_to_process)
    print(f"Generating {total} voice samples...")

    # Initialize sherpa-onnx Kokoro TTS
    model_path = str(model_dir / "model.onnx")
    voices_path = str(model_dir / "voices.bin")
    tokens_path = str(model_dir / "tokens.txt")
    data_dir = str(model_dir / "espeak-ng-data")
    dict_dir = str(model_dir / "dict") if (model_dir / "dict").exists() else ""

    # Build lexicon paths
    lexicon_files = ["lexicon-us-en.txt", "lexicon-gb-en.txt", "lexicon-zh.txt"]
    lexicons = ",".join(
        str(model_dir / f) for f in lexicon_files
        if (model_dir / f).exists()
    )

    kokoro_config = sherpa_onnx.OfflineTtsKokoroModelConfig(
        model=model_path,
        voices=voices_path,
        tokens=tokens_path,
        data_dir=data_dir,
        dict_dir=dict_dir,
        lexicon=lexicons,
    )
    model_config = sherpa_onnx.OfflineTtsModelConfig(kokoro=kokoro_config)
    tts_config = sherpa_onnx.OfflineTtsConfig(model=model_config)

    print(f"Initializing sherpa-onnx Kokoro TTS from {model_dir}...")
    tts = sherpa_onnx.OfflineTts(tts_config)
    print(f"  {tts.num_speakers} speakers, {tts.sample_rate} Hz")

    generated = []

    for lang, voice_id, sid in voices_to_process:
        sample_text = SAMPLE_TEXTS.get(lang, SAMPLE_TEXTS["en"])
        mp3_name = f"kokoro-{voice_id}.mp3"
        mp3_path = output_dir / mp3_name
        print(f"  {voice_id} (sid={sid}) -> {mp3_name}...", end=" ", flush=True)

        try:
            audio = tts.generate(text=sample_text, sid=sid, speed=1.0)
            samples = np.array(audio.samples, dtype=np.float32)

            if len(samples) == 0:
                print("FAILED: 0 samples")
                continue

            # Write WAV to temp file
            import wave
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                wav_path = tmp.name
            with wave.open(wav_path, "w") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(audio.sample_rate)
                int16_samples = (samples * 32767).clip(-32768, 32767).astype(np.int16)
                wf.writeframes(int16_samples.tobytes())

            # Convert to MP3
            subprocess.run(
                ["ffmpeg", "-y", "-i", wav_path, "-ar", str(MP3_SAMPLE_RATE),
                 "-b:a", MP3_BITRATE, "-ac", "1", str(mp3_path)],
                capture_output=True, check=True,
            )
            os.unlink(wav_path)

            size_kb = mp3_path.stat().st_size // 1024
            duration_s = len(samples) / audio.sample_rate
            print(f"OK ({size_kb} KB, {duration_s:.1f}s)")
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


def _voice_to_sid(voice_id: str) -> int:
    """Look up speaker ID from the VOICES dict."""
    for _lang, voice_list in VOICES.items():
        for vid, sid in voice_list:
            if vid == voice_id:
                return sid
    return 0


def _has_command(cmd: str) -> bool:
    return subprocess.run(
        ["which", cmd], capture_output=True
    ).returncode == 0


if __name__ == "__main__":
    main()
