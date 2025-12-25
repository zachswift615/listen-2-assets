# Listen2 Assets

Public assets for the Listen2 app.

## Voice Models

Piper TTS voice models repackaged as `.tar.zst` for fast decompression.

Download voices from [Releases](../../releases).

## Repackaging Script

To repackage voices from the original bz2 format:

```bash
./scripts/repackage-all-english-voices.sh
```

To repackage and upload to GitHub Releases:

```bash
./scripts/repackage-all-english-voices.sh --upload
```
