# Architecture and delivery plan

The product requirements live in [requirment.md](../requirment.md). The first milestone helps a Mac user answer two questions offline: how much space a mounted volume reports, and which folders or files account for the bytes visible under a folder they choose. Scanning is always read-only. An interrupted or incomplete observation must be visible to the user.

## Phase 0 decisions

| Decision | Reason |
| --- | --- |
| A Swift package with a macOS 13 deployment target and an app bundle assembled from its executable | Supports native SwiftUI and AppKit development with the Command Line Tools. A local build has no third-party dependencies. |
| A small StorageCore library with immutable scan models, a scanner, and a volume service | Filesystem behavior can be exercised directly with disposable files. Views consume the same results that the tests inspect. |
| One background traversal per active scan, with a bounded set of displayed results | Limits simultaneous I/O and lets the window continue to respond to input. Retaining directory identities and multiply-linked file identities trades memory for accurate deduplication. |
| User-selected scan roots, a single filesystem per scan, and no file-content reads | Limits the scope of work and avoids reading personal documents or triggering content downloads to calculate size. |
| In-memory observations for the first milestone | The app has no need to retain filenames, permissions, or bookmarks across launches until history or monitoring ships. |
| Separate folder accounting from mount capacity | APFS volumes can share container space. Clones and snapshots can share extents. Adding folder allocations across a tree cannot predict how much space an operation would recover. [Apple File System Guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/Features/Features.html) |

## Project structure

- `Sources/StorageCore` owns scanner policy, metadata accounting and volume queries.
- `Sources/StorageApp` owns folder selection, security scope lifetime, task coordination, dashboard, and explorer.
- `Tests` contains disposable fixture coverage. GUI acceptance and release compatibility checks are tracked separately.
- `Scripts` contains local build and validation entry points. No build step requires a distribution identity.

## Permissions and threat model

| Surface or risk | Decision and remaining validation |
| --- | --- |
| Directory names, links, package contents, or mutable trees | Descend from open directory handles, skip symbolic links and foreign device identities, and report errors. Packages contribute their files to aggregate size. Enumeration is a point-in-time observation across multiple system calls. A file may change after it is measured. |
| Sensitive paths and privacy prompts | Start scans only after folder selection. Balance security-scoped access where granted. Permission errors leave a partial scan. Protected locations may require user action in Privacy & Security. Full Disk Access is optional and normal filesystem permissions still apply. [Apple Platform Security](https://support.apple.com/en-mide/guide/security-pdf/secddd1d86a6/1/web/1) |
| Sandbox distribution | Use a user-selected read-only entitlement with the macOS Open panel. Design future recurring scans around scoped bookmarks, stale-bookmark recovery, and revocation. Test these in a signed sandboxed bundle before shipping through the store. [App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox) · [Security-scoped URLs](https://developer.apple.com/documentation/foundation/nsurl/) |
| Direct distribution | Use a Developer ID signature, hardened runtime and notarization before public distribution. The local development app runs with the user's existing permissions. Never request elevation for scanning. |
| Storage exhaustion or a very large tree | Bound largest-file, issue-detail and visible-directory lists, expose truncation and preserve aggregates. Benchmark directory-heavy and hard-link-heavy trees before claiming million-entry scalability. |
| Dangerous deletion or untrusted executables | The first milestone has no cleanup executor. Any future executor requires its own allowlists, race checks, supported app-specific operations, confirmation, audit trail and fixture tests. No automated removal of databases, models, snapshots or protected volumes. |

## Compatibility matrix

| Configuration | Validation |
| --- | --- |
| macOS 13 Ventura and later, arm64 and x86_64 | Minimum deployment target. Compile for each architecture. Runtime compatibility on Ventura and Intel requires dedicated machines. |
| Development host | macOS 27.2.1 (26B131), arm64, Apple Swift 6.4.2, macOS SDK 27.2 and Command Line Tools. No full Xcode at the standard application locations. No valid signing identity was listed by the user keychain. |
| APFS, external and removable filesystems | Use filesystem metadata reported by the selected mount. Physical allocation estimates and permission behavior can vary by filesystem. Physical media, mount races and signed sandbox/TCC behavior require manual coverage. |

## Delivery milestones and acceptance

1. **Phase 1 — analysis.** Build the native window, report real volume statistics, scan one selected folder, stream progress, support cancellation, expose a folder tree, largest files and partial coverage. Exercise traversal, links, sparse files, boundaries, errors and presentation limits with fixtures. Build a runnable bundle.
2. **Phase 2 — recommendations.** Classify known targets with stable rules, ownership, confidence, risk, consequences, and recovery estimates. Preview recommendations against fixtures and include protected-path exclusions.
3. **Phase 3 — authorized cleanup.** Add one independently validated mechanism at a time. Require dry-run, consent, target revalidation, partial-failure handling and post-operation measurement. Use disposable fixtures for destructive tests.
4. **Phase 4 — monitoring and diagnostics.** Add history with retention and migrations, APFS context, treemap, low-storage notifications, power-aware scheduling and performance measurements.
5. **Phase 5 — release.** Exercise VoiceOver, Keyboard Navigation, Dark Mode, both architectures and the supported OS range. Validate the distribution sandbox or notarized build, CI, DMG, privacy disclosures, naming, licensing and incident reporting before a public release.

Milestone 2 brings the interactive treemap forward into the read-only analysis release. See the [Milestone 2 guide and validation record](MILESTONE-2.md).
