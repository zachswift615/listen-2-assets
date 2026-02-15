# Listen2 Assets

Public assets for the Listen2 app — voice models and grammar packs.

Download from [Releases](../../releases).

## Voice Models

Piper TTS voice models repackaged as `.tar.zst` for fast decompression.

### Repackage voices

```bash
# Single language
./scripts/repackage-voices.sh es

# All supported languages
./scripts/repackage-voices.sh all

# Repackage and upload to GitHub release
./scripts/repackage-voices.sh es --upload
```

Run without arguments to see supported languages and voice counts.

## Grammar Packs

NeMo text normalization grammars packaged as `grammar-{lang}.tar.zst`. These enable proper pronunciation of numbers, dates, currency, etc.

Source grammars come from the [text-normalizer](https://github.com/zachswift615/text-normalizer) project at `~/projects/text-normalizer/nemo-grammars/`.

### Package grammars

```bash
# Single language
./scripts/package-grammars.sh es

# All languages + generate manifest
./scripts/package-grammars.sh all --manifest

# Package, generate manifest, and upload
./scripts/package-grammars.sh all --upload --manifest
```

Run without arguments to see available languages and source sizes.

### Grammar manifest

The `--manifest` flag generates `grammar-manifest.json` with SHA256 checksums and sizes for each grammar. The app uses this to verify downloads and detect updates.

## Release structure

All assets live on the `voices-v1` release:

```
voices-v1/
  vits-piper-en_US-lessac-medium.tar.zst
  vits-piper-es_ES-davefx-medium.tar.zst
  grammar-en.tar.zst
  grammar-es.tar.zst
  grammar-manifest.json
  ...
```

## Legacy

The original English-only script is at `scripts/repackage-all-english-voices.sh`. Use `scripts/repackage-voices.sh en` instead.
