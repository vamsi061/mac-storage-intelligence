# Build a Production-Grade Native macOS Storage Analyzer and Safe Cleanup Application

## Role

You are the principal macOS engineer, Swift architect, filesystem specialist, security engineer, UI/UX designer, QA lead, and release engineer responsible for delivering a public-facing macOS application.

Build a native, professional, secure, performant storage analysis and cleanup application for macOS.

**Working product name:** Mac Storage Intelligence (temporary; verify naming and trademark availability before public release).

This is a real software engineering project, not a prototype, mockup, or demonstration.

Your responsibility is to implement, test, document, and progressively deliver a working application with production-quality foundations.

## 1. Product Vision

Create a macOS application that helps users:

- Understand exactly how their disk storage is being used.
- Explore large directories and files visually.
- Identify applications, caches, development tools, downloads, and AI models consuming space.
- Receive clear, evidence-based cleanup recommendations.
- Safely recover storage with explicit user authorization.
- Monitor storage growth over time.
- Detect unexpected increases in disk usage.
- Understand why available space differs from ordinary folder-size calculations.
- Manage storage without repeatedly using Terminal.

The application must be suitable for public distribution, including nontechnical users.

Core principle:

**Never sacrifice user data safety for higher cleanup numbers.**

## 2. Supported Platforms

Target macOS 13 Ventura and newer initially, including Intel x86_64 and Apple Silicon arm64.

Verify the actual deployment target against every selected API and dependency.

Design compatibility abstractions for different macOS releases.

Use native macOS development technologies.

Preferred stack:

- Swift
- SwiftUI
- AppKit where necessary
- Foundation and FileManager
- POSIX filesystem APIs where appropriate
- Disk Arbitration and supported filesystem APIs
- Swift Charts
- SQLite or another justified local persistence mechanism
- XCTest and Swift Testing where supported
- Swift Package Manager
- Xcode project or an equivalent reproducible native build setup

Avoid Electron, web wrappers, embedded web servers, unnecessary Python dependencies, and mandatory cloud services.

The application must function completely offline.

## 3. Development Environment

First inspect the actual host environment.

Determine:

- macOS version
- CPU architecture
- Swift version
- Xcode and command-line tools availability
- Code signing availability
- Existing repository state

Do not assume that a full Xcode installation is present.

If the available environment cannot compile or test the app, still implement the source code and report the limitation precisely.

Never claim that a build, test, signing operation, or UI validation succeeded without executing it.

Do not install large development tools without asking.

## 4. Application Interface

Build a polished native macOS interface with:

### Dashboard

- Total storage capacity
- Used space
- Available space
- Purgeable space where reliably available
- Volume selection
- Storage utilization visualization
- Last successful scan timestamp
- Scan coverage and permission status
- Top storage consumers
- Cleanup recommendations
- Estimated recoverable storage
- Historical storage trends

### Storage Explorer

Provide:

- Hierarchical directory tree
- Folder-size aggregation
- Largest-file discovery
- Sorting by size, name, and modification date
- Search and filtering
- File-type categorization
- Treemap visualization
- Breadcrumb navigation
- Finder integration
- Open containing folder
- Scan progress and cancellation
- Clear indication of inaccessible folders

### Cleanup Center

Display cleanup candidates with:

- Human-readable name
- Exact target location
- Size
- Risk classification
- Reason for recommendation
- Consequences of deletion
- Whether files can be regenerated
- Whether applications must be closed
- Expected recovery
- Required user action

Risk categories:

1. Regenerable cache
2. Review recommended
3. High risk / application data
4. Protected / never automatically delete

Never describe an action as completely risk-free.

### History

Provide:

- Storage snapshots
- Growth trends
- Largest growing folders
- Storage recovered per cleanup operation
- Cleanup history
- Failed cleanup records
- Configurable low-storage notifications

### Settings

Provide:

- Appearance and theme
- Scan exclusions
- Scan scheduling
- Notification thresholds
- Privacy controls
- Data retention
- Permission management
- Advanced diagnostic options

Use native navigation, keyboard shortcuts, accessibility labels, VoiceOver support, Dark Mode, and responsive layouts.

Do not build a decorative dashboard that uses fake values in production.

## 5. Filesystem Scanning Engine

Implement a high-performance asynchronous scanner.

Requirements:

- Recursive directory traversal
- Cancellation support
- Progress reporting
- Incremental results
- Bounded concurrency
- Low memory overhead
- No unnecessary file-content reads
- No following symbolic links by default
- Protection against traversal cycles
- Hard-link deduplication where appropriate
- Filesystem boundary awareness
- APFS clone and shared-extent accounting limitations
- Sparse-file handling
- Package-directory handling
- Accurate permission-error reporting
- External and removable volume support
- Exclusion rules
- Graceful handling of files that change during scanning

Distinguish:

- Logical file size
- Allocated size
- Directory aggregate size
- Filesystem-reported used space
- Available space
- Potentially purgeable space
- Estimated recoverable space

Do not assume directory totals must equal APFS volume usage.

Do not double-count firmlinked paths, mounted volumes, or hard-linked files.

Recognize that APFS clones and snapshots may prevent a simple file deletion from recovering the apparent file size.

Use supported macOS APIs where available. If accurate physical allocation cannot be determined, explicitly label the value as an estimate.

## 6. APFS and System Storage

Implement an APFS-aware diagnostics module.

Show:

- APFS container information
- Volume information
- System and Data volume roles
- Snapshots where accessible
- Volume-level capacity
- Differences between directory scans and filesystem accounting

Handle macOS System/Data volume separation and firmlinks correctly.

Do not modify sealed system volumes, Preboot, Recovery, or system-managed virtual memory.

Do not automatically delete snapshots.

Provide explanations for inaccessible or system-managed storage.

## 7. Cleanup Rules Engine

Implement a deterministic, extensible rule system.

Initial supported categories:

### Developer tooling

- npm cache
- pnpm store
- Yarn cache
- Bun cache
- pip cache
- uv cache
- Gradle cache
- Maven cache
- Xcode DerivedData
- SwiftPM build artifacts
- Homebrew outdated downloads and caches
- Docker and Colima storage
- Python virtual environments
- Node.js build outputs
- Browser automation caches

### AI and machine learning

- Hugging Face model cache
- Ollama models
- Local model directories
- Downloaded model checkpoints
- Temporary inference artifacts
- AI application caches

### General macOS storage

- Downloads
- Large disk images
- Old archives
- Duplicate candidates
- Application caches
- Browser caches
- Old installer packages
- User-selected temporary files
- Large logs

For each rule, define:

- Stable rule identifier
- Discovery logic
- Ownership and scope
- Risk classification
- Detection confidence
- Supported macOS versions
- Whether the target is currently in use
- Estimated recovery
- Preferred cleanup mechanism
- Required confirmations
- Recovery or reinstallation implications

Prefer official cleanup commands or supported application APIs where they exist.

For example, use package-manager cache-cleaning mechanisms instead of blindly deleting arbitrary directories.

Treat virtual machines, containers, model weights, application databases, and user documents as valuable data by default.

## 8. Cleanup Execution and Security

Design a dedicated cleanup execution layer.

Mandatory requirements:

- Read-only scanning by default
- Explicit confirmation before every destructive operation
- Dry-run previews
- Target validation immediately before deletion
- Path canonicalization
- Protection against symlink and path-substitution attacks
- Protection against race conditions where feasible
- Strict allowlists for automated cache rules
- No arbitrary shell interpolation
- No untrusted executable invocation
- No broad recursive deletion based only on a folder name
- No hidden background deletion
- No unnecessary administrator privileges
- Detailed action logs
- Partial-failure handling
- Cancellation where practical
- Post-cleanup free-space verification

Prefer moving user-selected ordinary files to Trash where supported.

Explain that moving files to Trash does not necessarily reclaim disk capacity until Trash is emptied.

For supported cache cleanup, use the correct application-specific operation.

Never promise rollback for irreversible operations.

Do not automatically delete active databases or model directories.

Block deletion of protected system paths.

Use explicit security boundaries for any privileged operations.

If privileged functionality is necessary, design and justify a narrowly scoped helper rather than running the entire application as root.

## 9. Permissions and Privacy

Design for macOS privacy and security requirements.

Support:

- User-selected folder authorization
- Security-scoped bookmarks where applicable
- Graceful handling of TCC restrictions
- Full Disk Access guidance when appropriate
- Clear explanation of inaccessible data
- Minimal permissions
- Local-only processing
- No telemetry by default
- No collection of file contents
- No uploading filenames or filesystem paths

Evaluate both:

1. Sandboxed Mac App Store distribution
2. Signed and notarized direct distribution

Document capability and permission trade-offs.

Do not assume that Full Disk Access bypasses all macOS security restrictions.

Do not bypass System Integrity Protection.

## 10. Background Monitoring

Implement an efficient storage monitoring subsystem.

Requirements:

- Configurable scan intervals
- Incremental or targeted rescanning where feasible
- Persistent historical snapshots
- Low-storage notifications
- Growth anomaly detection
- Minimal battery impact
- Minimal CPU and disk I/O
- Pause monitoring on battery or under heavy system load where appropriate

Do not continuously perform full-disk scans.

Use supported background execution mechanisms and clearly document lifecycle limitations.

## 11. Performance Requirements

Target:

- Responsive UI during scans
- Bounded memory usage
- Efficient traversal of large directory trees
- No full-file reads for size calculations
- Graceful operation on nearly full disks
- Scalable handling of millions of filesystem entries
- Avoidance of redundant scans
- Efficient local database writes

Define measurable performance benchmarks and test them.

Do not claim performance targets have been achieved without benchmark evidence.

## 12. Project Architecture

Use modular architecture with clear responsibilities.

Suggested modules:

- App
- Dashboard
- StorageScanner
- FilesystemModels
- APFSDiagnostics
- CleanupRules
- CleanupExecutor
- Permissions
- StorageHistory
- Notifications
- Settings
- SharedUI
- Tests

Use protocols and dependency injection for testability.

Separate scanning, classification, and deletion.

Avoid excessive abstraction and unnecessary third-party dependencies.

## 13. Testing

Implement automated tests for:

- Directory traversal
- Symlink cycles
- Hard links
- Sparse files
- Permission failures
- Cancellation
- Large directories
- File changes during scanning
- Filesystem boundaries
- Risk classification
- Cleanup rule matching
- Protected path rejection
- Path traversal attempts
- Symlink substitution
- Active database protection
- Cleanup dry runs
- Post-cleanup verification
- Storage history
- Migration compatibility

Create disposable test fixtures.

Never run destructive tests against the developer's real home directory.

Include integration tests and performance benchmarks.

Test on supported Intel and Apple Silicon configurations when hardware or CI environments are available.

Clearly distinguish executed tests from tests that still require hardware or manual validation.

## 14. Release Engineering

Prepare:

- Reproducible builds
- Unit and integration test workflows
- CI configuration
- Universal binary build process
- Signing configuration
- Notarization workflow
- DMG distribution
- Versioning strategy
- Release notes
- Privacy policy draft
- License decision documentation
- User documentation
- Troubleshooting guide
- Crash-reporting strategy
- Security disclosure process

Never hard-code signing credentials or secrets.

Do not claim Apple notarization or App Store approval without actual verification.

## 15. Implementation Workflow

Work incrementally.

### Phase 0 — Architecture and feasibility

Inspect the environment.

Research compatibility and permission constraints.

Produce:

- Product requirements
- Architecture decisions
- Threat model
- Compatibility matrix
- Project structure
- Delivery milestones
- Risk register

Then proceed to implementation.

### Phase 1 — Working application

Implement:

- Native SwiftUI shell
- Navigation
- Volume capacity reporting
- Folder scanning
- Progress reporting
- Folder tree
- Largest-files list
- Real filesystem data
- Permission and error reporting

Build and test the application.

### Phase 2 — Cleanup recommendations

Implement:

- Rule registry
- Cache detection
- Risk classification
- Cleanup preview
- Recovery estimates
- Protected-path rules

Keep destructive execution disabled until safety tests pass.

### Phase 3 — Safe cleanup

Implement:

- Explicit confirmations
- Validated execution
- Trash integration
- Supported package-manager cleanup
- Post-cleanup verification
- Action history

### Phase 4 — Advanced capabilities

Implement:

- Treemap
- Historical storage trends
- Notifications
- APFS diagnostics
- Performance optimization

### Phase 5 — Public release

Implement:

- Accessibility
- Compatibility validation
- Security audit
- CI
- Packaging
- Signing/notarization configuration
- Release documentation

## 16. Definition of Done

A feature is complete only when:

1. It is implemented in source code.
2. It is integrated into the application.
3. It has appropriate automated tests.
4. Its failure modes are handled.
5. It has been built and validated where the environment permits.
6. It uses real filesystem data.
7. It is documented.
8. Its known limitations are disclosed.

Never substitute a mock interface for working functionality without explicitly labeling it.

Never fabricate test results.

## 17. Agent Execution Rules

- Start by inspecting the repository and host environment.
- Create an actionable implementation plan.
- Record architectural decisions.
- Implement directly in the repository.
- Prefer small, verifiable milestones.
- Run builds and tests after significant changes.
- Fix failures before moving forward.
- Keep source files organized.
- Commit coherent changes when repository permissions permit.
- Preserve existing working functionality.
- Never delete unrelated local files.
- Never perform actual cleanup against the host during development unless explicitly authorized.
- Do not stop after writing specifications.
- Do not present unfinished code as production-ready.
- Clearly report blockers rather than silently skipping work.

At the end of each milestone report:

- Implemented functionality
- Files created or modified
- Tests executed
- Build result
- Known limitations
- Remaining work
- Next implementation priority

## 18. Begin Now

Start with Phase 0 and Phase 1.

Inspect the actual development environment and repository.

Produce the architecture and then implement a working native macOS application with real storage scanning, a responsive SwiftUI dashboard, a directory explorer, and appropriate tests.

Continue through the planned work as the environment and available execution time permit.

Do not execute destructive cleanup operations.

Prioritize a functional, tested storage scanner over visual polish.
