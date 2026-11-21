# Mac Storage Intelligence

A native macOS storage manager: measure what is using disk, browse and search every
accessible folder, discover developer caches and AI models, monitor changes in real
time, and delete selected files or resources safely. Everything runs locally, with
no account, subscription, network service or API key.

![Mac Storage Intelligence icon](Resources/AppIcon-1024.png)

## Screens

- **Overview** — real volume capacity (total, used, available, shared), an
  interactive capacity breakdown, a short available-space trend, the last folder
  scan, and entry points to every tool.
- **Storage explorer** — breadcrumb file browser with expandable monitored tree,
  treemap, hidden-file visibility, type filtering, search, sorting by name, size,
  type and modification date, file metadata, Quick Look preview, Finder reveal,
  multi-selection and per-item or bulk deletion.
- **Large files** — the largest measured files or directories across monitored
  volumes, with the same filters and deletion actions.
- **Applications** — installed `.app` bundles with measured size, associated
  support-folder discovery, and Trash-based removal with warnings.
- **AI models** — Ollama models through the local service, Hugging Face cached
  repositories through the `hf` CLI, and standalone GGUF/ONNX/safetensors weights
  found in supported inference folders or scan results.
- **Developer storage** — npm, pnpm, yarn, uv and Homebrew caches with their own
  cleanup commands, plus Docker/Colima containers and images with per-resource
  removal. Protected volumes are listed but not removable.
- **Cleanup** — standard cache, log, build and model locations classified as
  Safe to Clean, Review Required or Protected, with explanations, estimates and
  confirmed actions.
- **History** — every deletion attempt, its outcome, and the observed available
  space change.
- **Settings** — volume inventory toggles, custom exclusions, monitoring status,
  permission guidance and safety notes.

## Deletion

Selected items are inspected immediately before deletion: path components are
opened without following symlinks, the containing directory is pinned, and file
identity (device, inode, generation) plus contents are revalidated. Deletion runs
through a private staging directory so a path replacement cannot redirect the
operation.

- **Move to Trash** is the default for ordinary files and folders. Items remain on
  the source volume until Trash is emptied and can be restored in Finder.
- **Delete Permanently** is available only after an explicit destructive
  confirmation. It removes files and directory trees through descriptor-relative
  unlinks and never silently falls back from Trash.
- Protected system locations, application bundles outside `/Applications`,
  application data, databases, virtual-machine disks, managed model stores and
  files currently open by a visible process are refused.
- Ollama deletion uses the service API and verifies the model disappears.
  Hugging Face deletion uses `hf cache rm`. Docker uses the engine API and refuses
  volumes. Package caches use their official cleanup commands, sandboxed to the
  selected cache.
- Recovery is measured before and after. Logical size is not reported as
  physically recovered space: APFS clones, snapshots, shared model blobs, Docker
  layer sharing and delayed Trash reclamation can all reduce or delay recovery.

## Monitoring

- The last scanned folder resumes automatically at launch; the first run starts
  with `~/Library/Caches` to avoid triggering privacy prompts.
- Volume capacity is sampled about once per second (selected volume every second,
  the mount list every ten).
- FSEvents updates affected folders incrementally; continuous changes are debounced
  and rate-limited.
- Periodic full verification corrects dropped events. Automatic inventory scans
  skip privacy-protected home locations (`Desktop`, `Documents`, `Downloads`,
  `Pictures`, `Movies`, `Music`, `Library/Containers`, `Library/Group Containers`,
  `Library/Safari`, `Library/Mail`, `Library/Messages`, `Library/CloudStorage`,
  `Library/Application Support/com.apple.TCC`, `.Trash`) unless the user selects
  them explicitly.
- No Refresh button is required.

## Permissions

macOS protects Desktop, Documents, Downloads, Photos and other locations. The app
never bypasses System Integrity Protection or TCC. Choose a folder through the
system panel to grant access to it, or grant Full Disk Access in **System Settings
→ Privacy & Security** for whole-disk inventory. Locations that cannot be read are
listed as partial coverage, never as fully scanned.

## Build and verify

```sh
# Core fixture checks (scanner, deletion, AI models, developer storage, monitoring)
Scripts/test-scanner.sh

# Real application-model checks: launch scan, FSEvents updates, reconciliation,
# capacity cadence, CPU/memory/disk sampling
Scripts/test-monitoring-model.sh

# Disposable APFS mount-boundary integration test
Scripts/test-scanner.sh --mount-boundary

# Regenerate the app icon
swift Scripts/make-icon.swift

# Build the universal app and verified DMG
Scripts/package-dmg.sh
```

`package-dmg.sh` builds arm64 and x86_64, assembles the bundle with
`Resources/AppIcon.icns`, ad-hoc signs it, verifies the DMG, and installs both
artifacts in `dist/`.

## Verification status

- 22 standalone fixture checks pass, including Trash and permanent deletion,
  protected paths, symlink replacement, partial failure, AI model enumeration and
  caching, developer caches, incremental updates and FSEvents delivery.
- Full application-model test passes: 0.16% mean idle CPU, 0.66% mean CPU across
  the run, ~20 MB RSS, 1.04 s mean capacity cadence, 0.8–3 s incremental updates,
  missed-event repair within 14 s, and no overlapping measurements.
- Universal app launches and DMG verifies on the build machine.
- macOS 13 runtime and physical Intel hardware remain untested.

## Installation

Open `dist/Mac Storage Intelligence.dmg`, drag **Mac Storage Intelligence.app**
into Applications, and eject.

The build is **ad-hoc signed and not notarized**. On first launch use right-click →
Open, or allow it under **System Settings → Privacy & Security**. It is not
Developer ID signed and is not ready for unrestricted public distribution.

## Known limitations

- Ad-hoc signature only; no notarization.
- Whole-disk inventory requires Full Disk Access; without it, protected folders
  remain unmeasured and are marked as such.
- Ollama and Docker integrations require those services to be running; Hugging
  Face removal requires the `hf` CLI. Optional tools are hidden when absent.
- Recovery figures are estimates; APFS snapshots, clones and shared blobs can keep
  blocks allocated after deletion.
- Traversal is metadata-only; file contents are never opened.

## License

MIT — see [LICENSE](LICENSE).
