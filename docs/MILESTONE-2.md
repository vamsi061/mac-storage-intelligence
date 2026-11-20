# Milestone 2 — read-only storage analysis

Build with `Scripts/build-app.sh --universal` and open `.build/Mac Storage Intelligence.app`. Choose **Scan Folder…**. Overview reports filesystem capacity separately from the most recent folder scan. Browse Folder tree, switch to Treemap, and select a tile to explore a subfolder. Breadcrumbs return to an ancestor. Largest files supports filtering, sorting, and revealing a result in Finder.

## What the preview measures

The rule registry matches observed directories under a standard local account home. It recognizes npm, pnpm, pip, uv, Homebrew downloads, Gradle caches, Xcode DerivedData, Hugging Face, Ollama, Docker Desktop, Colima, Safari and Chrome caches, and Documents. Each row shows its path, risk, logical bytes, measured allocation, rationale, and consequences. A custom package store, a relocated home, or a directory outside the retained tree can produce no match. Empty results apply only to the selected scan.

Caches and rebuildable artifacts have a possible recovery range from zero to their observed allocation. APFS clones, shared blocks, hard links, and snapshots can reduce what is freed. Model and VM data receive no recovery estimate. Protected content and incomplete traversal propagate up the folder tree, including from directories omitted by the display limit. Metadata and name indicators do not identify every possible database, disk image, or personal file.

After a scan, a cancellable background task checks visible processes using macOS libproc. A matching working directory or open file descriptor protects its candidate. Only matched candidate locations are retained. This observation is limited by permissions, changes in processes, a two-second observation budget, and a cap of 8,192 descriptors per process. Missing evidence leaves current use unknown. The application has no deletion, Trash, process-control, or package-maintenance action.

## Validation

The command-line fixture suite runs with `Scripts/test-scanner.sh`. Its cases exercise rule families, risk escalation, open database handles, permission errors, cancellation during traversal, ranking, bounded results, and treemap geometry. The optional `Scripts/test-scanner.sh --mount-boundary` check creates a temporary APFS image, verifies nested-mount exclusion and direct volume selection, and detaches it. Both paths passed on the Apple Silicon development Mac.

A 10,000-empty-file local fixture took 0.047 s before the largest-file ranking optimization and 0.035 s afterward in individual runs. Timing excludes fixture creation. This is a warm, flat-directory microbenchmark. Network volumes, deeply nested trees, memory use at million-entry scale, Intel hardware and Ventura runtime behavior still need separate validation.
