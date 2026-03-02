#!/usr/bin/env python3
"""Generate voice sample MP3s for all packaged Piper voices.

Uses sherpa-onnx to synthesize a "rainbow passage" in each language,
then converts to MP3 via ffmpeg. Output goes to repackaged-voices/samples/.

Usage:
    # Generate samples for specific languages:
    python scripts/generate-samples.py fr de

    # Generate samples for all languages with packaged voices:
    python scripts/generate-samples.py all

    # Upload generated samples to GitHub release:
    python scripts/generate-samples.py fr de --upload

Requires:
    - sherpa_onnx Python package (from ai_voice venv)
    - ffmpeg (for WAV→MP3 conversion)
    - zstd (for extracting voice archives)
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Rainbow passage in each language (from Wikipedia)
RAINBOW_PASSAGES = {
    "fr": (
        "Un arc-en-ciel est un photométéore, un phénomène optique se produisant "
        "dans le ciel, visible dans la direction opposée au Soleil quand il brille "
        "pendant la pluie. C'est un arc de cercle coloré d'un dégradé de couleurs."
    ),
    "de": (
        "Der Regenbogen ist ein atmosphärisch-optisches Phänomen, das als "
        "kreisbogenförmiges farbiges Lichtband in einer von der Sonne beschienenen "
        "Regenwand oder -wolke wahrgenommen wird."
    ),
    "ru": (
        "Радуга — атмосферное, оптическое и метеорологическое явление, "
        "наблюдаемое при освещении ярким источником света множества водяных "
        "капель дождя или тумана. Радуга выглядит как разноцветная дуга или "
        "окружность, составленная из цветов спектра видимого излучения."
    ),
    "it": (
        "In fisica dell'atmosfera e meteorologia, l'arcobaleno è un fenomeno "
        "atmosferico che produce uno spettro continuo di luce nel cielo quando "
        "la luce del Sole attraversa le gocce d'acqua rimaste in sospensione "
        "dopo un temporale, o presso una cascata o una fontana."
    ),
    "hu": (
        "A szivárvány olyan optikai jelenség, melyet eső- vagy páracseppek "
        "okoznak, mikor a fény prizmaszerűen megtörik rajtuk és színeire bomlik, "
        "kialakul a színképe, más néven spektruma. Az ív külső része vörös, "
        "míg a belső ibolya."
    ),
    "sv": (
        "En regnbåge är ett optiskt, meteorologiskt fenomen som uppträder som "
        "ett nästintill fullständigt ljusspektrum i form av en båge på himlen "
        "då solen lyser på nedfallande regn."
    ),
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
    "vi": (
        "Cầu vồng là hiện tượng quang học và khí tượng học tạo ra một quang phổ "
        "gần như liên tục của ánh sáng trên bầu trời khi ánh sáng Mặt Trời chiếu "
        "vào các giọt nước mưa. Đó là một cung tròn nhiều màu sắc với đỏ ở phía "
        "ngoài và tím ở phía trong."
    ),
}


def find_voice_archives(voices_dir: Path, lang_filter: list[str]) -> list[Path]:
    """Find all .tar.zst voice archives matching the language filter."""
    archives = []
    for f in sorted(voices_dir.glob("vits-piper-*.tar.zst")):
        # Extract language code from filename: vits-piper-{locale}-{name}-{quality}.tar.zst
        # locale is like fr_FR, de_DE, etc.
        stem = f.stem.replace(".tar", "")  # remove .tar from .tar.zst
        parts = stem.split("-")
        # vits-piper-fr_FR-gilles-low → parts = [vits, piper, fr_FR, gilles, low]
        if len(parts) >= 3:
            locale = parts[2]  # e.g., fr_FR
            lang = locale.split("_")[0]  # e.g., fr
            if "all" in lang_filter or lang in lang_filter:
                archives.append(f)
    return archives


def extract_voice(archive: Path, work_dir: Path) -> Path:
    """Extract a voice archive and return the extracted directory."""
    # Decompress zstd, then extract tar
    tar_path = work_dir / "voice.tar"
    subprocess.run(
        ["zstd", "-d", str(archive), "-o", str(tar_path), "--force", "-q"],
        check=True,
    )
    subprocess.run(
        ["tar", "xf", str(tar_path), "-C", str(work_dir)],
        check=True,
    )
    tar_path.unlink()

    # Find the extracted directory
    dirs = [d for d in work_dir.iterdir() if d.is_dir()]
    if not dirs:
        raise FileNotFoundError(f"No directory found after extracting {archive.name}")
    return dirs[0]


def get_speaker_info(voice_dir: Path) -> dict:
    """Read model JSON to get speaker count and ID map."""
    json_files = list(voice_dir.glob("*.onnx.json"))
    if not json_files:
        return {"num_speakers": 1, "speaker_id_map": {}}
    with open(json_files[0]) as f:
        data = json.load(f)
    return {
        "num_speakers": data.get("num_speakers", 1),
        "speaker_id_map": data.get("speaker_id_map", {}),
    }


def init_tts(voice_dir: Path, sherpa_onnx):
    """Initialize a TTS engine for a voice directory. Returns (tts, sample_rate) or None."""
    onnx_files = list(voice_dir.glob("*.onnx"))
    onnx_files = [f for f in onnx_files if not f.name.endswith(".onnx.json")]
    if not onnx_files:
        print(f"  No .onnx model found in {voice_dir.name}")
        return None

    model_path = str(onnx_files[0])
    tokens_path = str(voice_dir / "tokens.txt")
    data_dir = str(voice_dir / "espeak-ng-data")

    if not os.path.exists(tokens_path):
        print(f"  No tokens.txt in {voice_dir.name}")
        return None

    lexicon_path = ""
    lexicon_file = voice_dir / "lexicon.txt"
    if lexicon_file.exists():
        lexicon_path = str(lexicon_file)

    vits_config = sherpa_onnx.OfflineTtsVitsModelConfig(
        model=model_path,
        lexicon=lexicon_path,
        tokens=tokens_path,
        data_dir=data_dir,
    )
    model_config = sherpa_onnx.OfflineTtsModelConfig(
        vits=vits_config,
        num_threads=2,
        debug=False,
        provider="cpu",
    )
    tts_config = sherpa_onnx.OfflineTtsConfig(model=model_config)
    return sherpa_onnx.OfflineTts(tts_config)


def synthesize_to_wav(tts, text: str, sid: int, output_wav: Path) -> bool:
    """Synthesize text to WAV file using an initialized TTS engine."""
    import struct
    import wave

    try:
        audio = tts.generate(text=text, sid=sid, speed=1.0)
        if not audio.samples or len(audio.samples) == 0:
            return False

        with wave.open(str(output_wav), "w") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(2)
            wav_file.setframerate(audio.sample_rate)
            int_samples = [
                max(-32768, min(32767, int(s * 32767))) for s in audio.samples
            ]
            wav_file.writeframes(struct.pack(f"<{len(int_samples)}h", *int_samples))
        return True
    except Exception as e:
        print(f"  Synthesis error: {e}")
        return False


def synthesize_sample(
    voice_dir: Path, text: str, output_wav: Path, sherpa_onnx
) -> bool:
    """Synthesize text to WAV using sherpa-onnx (speaker 0)."""
    tts = init_tts(voice_dir, sherpa_onnx)
    if tts is None:
        return False
    return synthesize_to_wav(tts, text, 0, output_wav)


def convert_to_mp3(wav_path: Path, mp3_path: Path) -> bool:
    """Convert WAV to MP3 using ffmpeg."""
    try:
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-i",
                str(wav_path),
                "-codec:a",
                "libmp3lame",
                "-b:a",
                "64k",  # 64kbps is fine for voice samples
                "-ar",
                "22050",
                str(mp3_path),
            ],
            check=True,
            capture_output=True,
        )
        return True
    except subprocess.CalledProcessError as e:
        print(f"  ffmpeg error: {e.stderr.decode()[:200]}")
        return False


def voice_id_from_archive(archive: Path) -> str:
    """Extract voice ID from archive filename.

    vits-piper-fr_FR-gilles-low.tar.zst → vits-piper-fr_FR-gilles-low
    """
    return archive.name.replace(".tar.zst", "")


def lang_from_archive(archive: Path) -> str:
    """Extract language code from archive filename."""
    parts = archive.stem.replace(".tar", "").split("-")
    if len(parts) >= 3:
        return parts[2].split("_")[0]
    return ""


MOONQUAKE_SAMPLES_DIR = Path.home() / "projects" / "moonquakemedia-site" / "src" / "assets" / "listen2" / "samples"


def main():
    parser = argparse.ArgumentParser(
        description="Generate voice sample MP3s for Piper voices"
    )
    parser.add_argument(
        "languages",
        nargs="+",
        help='Language codes to process (e.g., "fr de") or "all"',
    )
    parser.add_argument(
        "--upload", action="store_true", help="Deploy samples to moonquakemedia-site (GitHub Pages CDN)"
    )
    parser.add_argument(
        "--voices-dir",
        default="./repackaged-voices",
        help="Directory containing voice .tar.zst files",
    )
    parser.add_argument(
        "--output-dir",
        default="./repackaged-voices/samples",
        help="Output directory for MP3 samples",
    )
    args = parser.parse_args()

    voices_dir = Path(args.voices_dir)

    # --upload generates directly into moonquakemedia-site (GitHub Pages CDN)
    if args.upload:
        output_dir = MOONQUAKE_SAMPLES_DIR
        if not output_dir.exists():
            print(f"Error: moonquakemedia samples dir not found: {output_dir}")
            print("Clone the moonquakemedia-site repo to ~/projects/moonquakemedia-site")
            sys.exit(1)
    else:
        output_dir = Path(args.output_dir)

    output_dir.mkdir(parents=True, exist_ok=True)

    if not voices_dir.exists():
        print(f"Error: voices directory not found: {voices_dir}")
        sys.exit(1)

    # Import sherpa_onnx
    try:
        import sherpa_onnx
    except ImportError:
        print("Error: sherpa_onnx not installed. Use the ai_voice venv:")
        print(
            "  /Users/zachswift/projects/ai_voice/venv/bin/python scripts/generate-samples.py ..."
        )
        sys.exit(1)

    # Find voice archives
    archives = find_voice_archives(voices_dir, args.languages)
    if not archives:
        print(f"No voice archives found for languages: {args.languages}")
        sys.exit(1)

    print(f"Found {len(archives)} voice archives to process")
    print(f"Output: {output_dir}\n")

    success = 0
    skipped = 0
    failed = 0
    failed_voices = []

    for archive in archives:
        voice_id = voice_id_from_archive(archive)
        lang = lang_from_archive(archive)
        mp3_path = output_dir / f"{voice_id}.mp3"

        # Skip if already generated (check for base file or speaker files)
        speaker_files = list(output_dir.glob(f"{voice_id}_speaker_*.mp3"))
        if mp3_path.exists() or speaker_files:
            count = len(speaker_files) if speaker_files else 1
            print(f"[skip] {voice_id} (already exists, {count} file{'s' if count > 1 else ''})")
            skipped += 1
            continue

        if lang not in RAINBOW_PASSAGES:
            print(f"[skip] {voice_id} (no rainbow passage for '{lang}')")
            skipped += 1
            continue

        # Check if multi-speaker by peeking at model JSON in the archive
        num_speakers = 1
        try:
            with tempfile.TemporaryDirectory() as peek_tmp:
                # Extract just the JSON config file
                subprocess.run(
                    ["zstd", "-d", str(archive), "-o", f"{peek_tmp}/a.tar", "--force", "-q"],
                    check=True, capture_output=True,
                )
                # List tar contents, find the .onnx.json
                tar_list = subprocess.run(
                    ["tar", "tf", f"{peek_tmp}/a.tar"],
                    capture_output=True, text=True, check=True,
                )
                json_file = next(
                    (l for l in tar_list.stdout.splitlines() if l.endswith(".onnx.json")),
                    None,
                )
                if json_file:
                    subprocess.run(
                        ["tar", "xf", f"{peek_tmp}/a.tar", "-C", peek_tmp, json_file],
                        check=True, capture_output=True,
                    )
                    with open(f"{peek_tmp}/{json_file}") as jf:
                        num_speakers = json.load(jf).get("num_speakers", 1)
        except Exception:
            pass

        if num_speakers > 1:
            print(f"[gen]  {voice_id} ({num_speakers} speakers)", flush=True)

            result = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).resolve()),
                    "--single",
                    str(archive),
                    lang,
                    str(mp3_path),
                    "--all-speakers",
                ],
                capture_output=True,
                text=True,
                timeout=600,  # more time for many speakers
            )

            if result.returncode == 0:
                try:
                    generated = json.loads(result.stdout.strip())
                    for name in generated:
                        size_kb = (output_dir / name).stat().st_size / 1024
                        print(f"       → {name} ({size_kb:.0f} KB)")
                    success += len(generated)
                except (json.JSONDecodeError, FileNotFoundError):
                    print(f"  FAILED (couldn't parse output)")
                    failed += 1
                    failed_voices.append(voice_id)
            else:
                reason = "segfault" if result.returncode < 0 else result.stdout.strip()[:100] or f"exit {result.returncode}"
                print(f"  FAILED ({reason})")
                failed += 1
                failed_voices.append(voice_id)
        else:
            print(f"[gen]  {voice_id}", flush=True)

            result = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).resolve()),
                    "--single",
                    str(archive),
                    lang,
                    str(mp3_path),
                ],
                capture_output=True,
                text=True,
                timeout=120,
            )

            if result.returncode == 0 and mp3_path.exists():
                size_kb = mp3_path.stat().st_size / 1024
                print(f"       → {mp3_path.name} ({size_kb:.0f} KB)")
                success += 1
            else:
                reason = "segfault" if result.returncode < 0 else result.stdout.strip()[:100] or f"exit {result.returncode}"
                print(f"  FAILED ({reason})")
                failed += 1
                failed_voices.append(voice_id)

    print(f"\n{'='*50}")
    print(f"Results: {success} generated, {skipped} skipped, {failed} failed")
    if failed_voices:
        print(f"Failed voices: {', '.join(failed_voices)}")
    print(f"{'='*50}")

    if args.upload and success > 0:
        print(f"\nSamples written to: {output_dir}")
        print("Remember to commit + push moonquakemedia-site to publish.")


def single_voice_main():
    """Subprocess entry point: synthesize voice sample(s).

    Called as: script.py --single <archive_path> <lang> <mp3_output_path> [--all-speakers]
    When --all-speakers is passed, generates one MP3 per speaker ID.
    The mp3_output_path is used as the base (speaker suffix appended).
    Runs in isolation so a segfault doesn't kill the parent batch.
    """
    import sherpa_onnx

    archive = Path(sys.argv[2])
    lang = sys.argv[3]
    mp3_base = Path(sys.argv[4])
    all_speakers = "--all-speakers" in sys.argv

    text = RAINBOW_PASSAGES[lang]

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        voice_dir = extract_voice(archive, tmp_path)

        if all_speakers:
            info = get_speaker_info(voice_dir)
            sid_map = info["speaker_id_map"]
            num_speakers = info["num_speakers"]

            tts = init_tts(voice_dir, sherpa_onnx)
            if tts is None:
                print("Failed to init TTS")
                sys.exit(1)

            # Build list of (sid, name) pairs
            if sid_map:
                pairs = [(sid, name) for name, sid in sid_map.items()]
            else:
                pairs = [(i, str(i)) for i in range(num_speakers)]

            generated = []
            for sid, name in sorted(pairs):
                wav_path = tmp_path / f"sample_{name}.wav"
                # Output: base_speaker_{name}.mp3
                stem = mp3_base.stem  # e.g., vits-piper-de_DE-thorsten_emotional-medium
                mp3_path = mp3_base.parent / f"{stem}_speaker_{name}.mp3"

                if synthesize_to_wav(tts, text, sid, wav_path):
                    if convert_to_mp3(wav_path, mp3_path):
                        generated.append(mp3_path.name)

            # Print generated files as JSON for parent to parse
            print(json.dumps(generated))
        else:
            wav_path = tmp_path / "sample.wav"
            if not synthesize_sample(voice_dir, text, wav_path, sherpa_onnx):
                print("Synthesis failed")
                sys.exit(1)
            if not convert_to_mp3(wav_path, mp3_base):
                print("MP3 conversion failed")
                sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--single":
        single_voice_main()
    else:
        main()
