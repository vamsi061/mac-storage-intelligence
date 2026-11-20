# Mac Storage Intelligence

A native macOS utility for understanding where disk space goes and reclaiming it
safely. It scans a folder or volume you choose, shows measured folder sizes and the
largest files, and surfaces standard cache, build and model locations for review.
Cleanup always requires explicit confirmation; nothing is deleted automatically.

![Mac Storage Intelligence icon](Resources/AppIcon-1024.png)

## Features

- **Storage dashboard** — real total, used and free capacity for each mounted
  volume, an interactive capacity breakdown, and the largest measured folders and
  files from the last scan.
- **Folder scanning** — allocated and logical sizes, nested directory tree, a
  treemap view, and the largest files table with search, sorting and filtering.
  Progress, cancellation, permission errors and coverage details are visible
  throughout. APFS mount boundaries are respected.
- **Cleanup recommendations** — detects standard locations for npm, pnpm, pip, uv,
  Homebrew, Gradle, Xcode Derived Data, Hugging Face, Ollama, Docker Desktop and
  Colima, plus aged log and temporary files. Each item is classified as
  **Safe to Clean**, **Review Required**, or **Protected** and explains what it is,
  what happens if removed, and how much space might be recovered.
- **Real cleanup** — supported ordinary files move to the same-volume Trash and
  can be restored in Finder. Apple's bundled pip can remove its own wheel cache
  through `pip cache remove`. Protected system paths, active files, application
  data, AI models and virtual machines are never deleted automatically.
- **Cleanup history** — every action, its outcome and the observed free-space
  change are stored locally.
- Native SwiftUI interface with sidebar navigation, light and dark mode, and no
  placeholder data.

## Requirements

- macOS 13 or later.
- Universal build for Apple Silicon and Intel.
- No account, subscription, network connection or `OPENAI_API_KEY`. The app works
  completely offline.

## Installation

1. Download `Mac Storage Intelligence.dmg` from the Releases page.
2. Open the DMG and drag **Mac Storage Intelligence.app** into Applications.
3. Eject the image.

The current DMG is **ad-hoc signed and not notarized**. On first launch, use
right-click → **Open**, or allow the app under **System Settings → Privacy &
Security**. It is not signed with a Developer ID and is not ready for unrestricted
public distribution through Apple's Gatekeeper on other Macs.

## Privacy

All scanning, analysis and cleanup happen on your Mac. The app sends no data
anywhere, has no analytics, and does not require a network connection. Reads are
limited to folders you explicitly choose; macOS may prompt for access under
Privacy & Security. History and the last scan date are stored in local user
defaults.

## Safety model

- Every cleanup requires an explicit confirmation sheet describing the exact path
  and consequences.
- Ordinary files are moved to Trash, which Finder can restore. Emptying Trash is a
  separate user action.
- Cleanup is deliberately limited to Trash moves for eligible ordinary files and
  the official pip cache mechanism. Other package managers and model stores are
  detected and explained, but require their own tools.
- Protected locations, active files, databases, application data, AI models and
  VM images are never cleaned automatically.
- Recovered space is measured, but APFS clones, snapshots and concurrent disk
  activity can make the observed change differ from the estimate.

## Build from source

```sh
# Run the standalone fixture suite (no Xcode required)
Scripts/test-scanner.sh

# Optional disposable APFS mount-boundary integration test
Scripts/test-scanner.sh --mount-boundary

# Build the app and DMG (universal)
Scripts/package-dmg.sh

# Regenerate the icon from Resources/AppIcon-source.png
swift Scripts/make-icon.swift
```

`Scripts/package-dmg.sh` builds the universal binary, assembles the app bundle with
`Resources/AppIcon.icns`, ad-hoc signs it, creates and verifies the DMG, then
installs the artifacts in `dist/`.

## Verification status

- The fixture suite reports 18 passing checks, including scanner traversal,
  cancellation, permission handling, volume measurements, Trash moves, pip
  cleanup, recommendations and treemap geometry.
- The disposable APFS mount-boundary integration test passes.
- The universal app launches and quits cleanly on the build machine.
- Runtime validation on macOS 13 and physical Intel hardware has not been
  performed.

## Limitations

- Ad-hoc signature only; no Developer ID signing or notarization.
- Only the cleanup paths described above are automated. Cache locations for other
  tools are reported for review rather than deleted.
- Process visibility is limited by macOS, so "in use" checks are best-effort.

## License

MIT — see [LICENSE](LICENSE).
