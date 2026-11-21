import AppKit
import Combine
import Foundation
import StorageCore
import os

@MainActor
final class StorageModel: ObservableObject {
    enum MonitoringState: Equatable {
        case idle
        case starting
        case active
        case unavailable(String)

        var label: String {
            switch self {
            case .idle: return "Monitoring idle"
            case .starting: return "Starting monitoring…"
            case .active: return "Monitoring changes"
            case .unavailable: return "Monitoring unavailable"
            }
        }
    }

    @Published var page: Destination? = .dashboard
    @Published private(set) var volumes: [StorageVolume] = []
    @Published var selectedVolumeID: URL?
    @Published private(set) var volumeError: String?
    @Published private(set) var refreshingVolumes = false

    @Published private(set) var activeFolder: URL?
    @Published private(set) var choosingFolder = false
    @Published private(set) var isCancelling = false
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var result: ScanResult?
    @Published private(set) var applicationsResult: ScanResult?
    @Published private(set) var applicationsError: String?
    @Published private(set) var applicationsLoading = false
    @Published private(set) var recommendations: [CleanupRecommendation] = []
    @Published private(set) var preparingPreview = false
    @Published private(set) var lastCompletedAt: Date?
    @Published var scanMessage: String?
    @Published var showFinderError = false
    @Published var showingCoverage = false

    @Published var confirmation: CleanupConfirmation?
    @Published private(set) var cleanupActivity: String?
    @Published private(set) var history: [CleanupRecord] = []

    // Automatic monitoring state.
    @Published private(set) var monitoringState: MonitoringState = .idle
    @Published private(set) var lastVerifiedAt: Date?
    @Published private(set) var lastIncrementalAt: Date?
    @Published private(set) var pendingChangeCount = 0
    @Published private(set) var isReconciling = false
    @Published private(set) var hasIncrementalChanges = false
    @Published private(set) var monitoringError: String?

    @Published var deletionSelection: SelectionRequest?
    @Published var browserLocation = FileManager.default.homeDirectoryForCurrentUser
    @Published private(set) var capacitySamples: [URL: [CapacitySample]] = [:]
    @Published private(set) var inventoryRevision = 0
    @Published private(set) var excludedFolders: [String]
    @Published private(set) var disabledMounts: Set<String>
    @Published private(set) var monitorAll: Bool
    private let inventoryWorker: Bool
    private let manageVolumes: Bool
    private let rootResolver: ScanRootResolver
    private(set) var mountWorkers: [URL: StorageModel] = [:]
    private var subscriptions: [URL: AnyCancellable] = [:]
    var inventoryResults: [ScanResult] {
        [result].compactMap { $0 } + [applicationsResult].compactMap { $0 } + mountWorkers.values.compactMap(\.result)
    }
    var allRecommendations: [CleanupRecommendation] {
        var paths = Set<String>()
        return (recommendations + mountWorkers.values.flatMap(\.recommendations)).filter { paths.insert($0.id).inserted }
    }

    struct RecoverableCandidate: Identifiable {
        let match: CleanupRecommendation
        let assessment: RecoverabilityAssessment
        var id: String { match.id }
        var bytes: Int64 { max(0, match.allocatedBytes) }
    }

    /// Candidates are limited to assessed, currently deletable resources. Paths are disjoint and
    /// protected/unknown app-managed locations are excluded, so this total cannot include a
    /// protected subtree twice.
    var recoverableCandidates: [RecoverableCandidate] {
        let policy = RecoverabilityPolicy()
        var targets = Set<String>()
        return allRecommendations.compactMap { match -> RecoverableCandidate? in
            let assessment = policy.assess(match)
            guard assessment.isDeletable, match.allocatedBytes > 0,
                  targets.insert(match.target.standardizedFileURL.path).inserted else { return nil }
            return RecoverableCandidate(match: match, assessment: assessment)
        }
    }

    var potentialRecoverableBytes: Int64 {
        recoverableCandidates.reduce(Int64(0)) { total, candidate in
            let (sum, overflow) = total.addingReportingOverflow(candidate.bytes)
            return overflow ? Int64.max : sum
        }
    }

    var storageBreakdown: StorageBreakdown {
        let primary = result.map { StorageBreakdown.MeasuredRoot(url: $0.root.url, allocatedBytes: $0.root.allocatedBytes) }
        let additional = ([applicationsResult].compactMap { $0 } + mountWorkers.values.compactMap(\.result))
            .filter { $0.root.url.standardizedFileURL != result?.root.url.standardizedFileURL }
            .map { StorageBreakdown.MeasuredRoot(url: $0.root.url, allocatedBytes: $0.root.allocatedBytes) }
        return StorageBreakdown(volume: selectedVolume, primaryRoot: primary, additionalRoots: additional,
                                recoverableBytes: potentialRecoverableBytes,
                                recoverableItems: recoverableCandidates.count)
    }

    func measuredNode(at url: URL) -> DirectoryNode? {
        let target = url.standardizedFileURL.path
        for scan in inventoryResults {
            guard let path = InventoryPaths.alias(of: url, under: scan.root.url),
                  let node = scan.deepestDirectory(containing: path), node.url.path == path else { continue }
            if node.url.standardizedFileURL.path == target || node.url.path == path { return node }
        }
        return nil
    }

    var applicationBundles: [DirectoryNode] {
        guard let root = applicationsResult?.root else { return [] }
        var result: [DirectoryNode] = []
        var stack = [root]
        while let node = stack.popLast() {
            if node.url.pathExtension.lowercased() == "app" { result.append(node) }
            else { stack.append(contentsOf: node.children) }
        }
        return result.sorted { $0.allocatedBytes > $1.allocatedBytes }
    }

    var aiModelBytes: Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [".ollama/models", ".cache/huggingface/hub", ".lmstudio/models",
                     ".cache/lm-studio/models", "Library/Application Support/Jan/data/models",
                     "Library/Application Support/nomic.ai/GPT4All"]
        return paths.reduce(Int64(0)) { total, path in
            let node = measuredNode(at: home.appendingPathComponent(path, isDirectory: true))
            let (sum, overflow) = total.addingReportingOverflow(node?.allocatedBytes ?? 0)
            return overflow ? Int64.max : sum
        }
    }

    var homeDownloadsBytes: Int64 {
        measuredNode(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true))?.allocatedBytes ?? 0
    }

    var homeCachesBytes: Int64 {
        measuredNode(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true))?.allocatedBytes ?? 0
    }
    private var scanOptions: ScanOptions {
        // Retain the complete accessible directory tree for this scope. The prior 20,000-node
        // cap stopped before Library/Caches and other cleanup ancestors on real home folders,
        // which made folders appear unmeasured and suppressed every cleanup recommendation.
        ScanOptions(largestFileLimit: 200, directoryLimit: 250_000, issueLimit: 200,
                    excludedPaths: Set(excludedFolders), minimumRetainedDepth: 5)
    }
    private let historyKey = "storage.cleanupHistory.v1"
    private static let lastScanKey = "storage.lastCompletedScanDate"
    private static let lastFolderKey = "storage.lastScannedFolder"

    private var volumeRequest = UUID()
    private var volumeTick = 0
    private var lastLoggedAvailable: Int64?
    private var scanTask: Task<Void, Never>?
    private var applicationScanTask: Task<Void, Never>?
    private var volumeLoop: Task<Void, Never>?

    private var eventMonitor: FileSystemEventMonitor?
    private var monitoredRoot: URL?
    private var pendingPaths: Set<String> = []
    private let defaults: UserDefaults
    private let defaultRoot: URL
    private let reconciliationInterval: TimeInterval
    private let reconciliationTick: TimeInterval
    typealias MonitorFactory = (URL, @escaping @Sendable ([FileSystemChange]) -> Void) -> FileSystemEventMonitor
    private let monitorFactory: MonitorFactory
    private var watchID = UUID()
    private var restartStream = false
    private var scopedRoot: URL?
    var incrementalUpdateInProgress: Bool { incrementalTask != nil }
    private var reducedActivity: Bool { !isApplicationActive || ProcessInfo.processInfo.isLowPowerModeEnabled }
    private var debounceTask: Task<Void, Never>?
    private var incrementalTask: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    private var lastReconciliationAttempt: Date?
    private var initialRetry: Task<Void, Never>?
    private var lastIncrementalBatchAt: Date?
    private var reconcileSoon = false
    private var reconciliationLoop: Task<Void, Never>?
    private var didStartInitialScan = false
    private var isApplicationActive = true

    private var recommendationsRunning = false
    private var recommendationsPending = false
    private var recommendationsGeneration = 0

    private static let log = Logger(subsystem: "local.macstorageintelligence.app", category: "monitoring")

    init(defaults: UserDefaults = .standard,
         defaultRoot: URL = FileManager.default.homeDirectoryForCurrentUser,
         inventoryWorker: Bool = false,
         reconciliationInterval: TimeInterval = 300, reconciliationTick: TimeInterval = 30,
         monitorFactory: @escaping MonitorFactory = { FileSystemEventMonitor(root: $0, handler: $1) }) {
        self.inventoryWorker = inventoryWorker
        manageVolumes = defaults === UserDefaults.standard && !inventoryWorker
        excludedFolders = defaults.stringArray(forKey: "inventory.exclusions") ?? []
        disabledMounts = Set(defaults.stringArray(forKey: "inventory.disabledMounts") ?? [])
        // Off by default: automatic whole-disk inventory can trigger macOS privacy prompts.
        // Users opt in from Settings, and explicit folder selection always grants access.
        monitorAll = defaults.object(forKey: "inventory.allMounts") as? Bool ?? false
        self.defaults = defaults
        self.defaultRoot = defaultRoot
        self.rootResolver = ScanRootResolver(home: defaultRoot)
        self.reconciliationInterval = reconciliationInterval
        self.reconciliationTick = reconciliationTick
        self.monitorFactory = monitorFactory
        if let data = defaults.data(forKey: historyKey) {
            do { history = try JSONDecoder().decode([CleanupRecord].self, from: data) }
            catch { scanMessage = "Cleanup history could not be read. " + error.localizedDescription }
        }
        lastCompletedAt = defaults.object(forKey: Self.lastScanKey) as? Date
        if !inventoryWorker { startVolumeUpdates() }
    }

    var isBusy: Bool { choosingFolder || activeFolder != nil || cleanupActivity != nil || confirmation != nil }

    var selectedVolume: StorageVolume? {
        volumes.first { $0.id == selectedVolumeID }
    }

    // MARK: - Volume capacity

    /// Polls mounted volumes once per second. This reads capacity metadata only; no folder is scanned.
    private func startVolumeUpdates() {
        volumeLoop?.cancel()
        volumeLoop = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let next = clock.now.advanced(by: .seconds(1))
                guard self != nil else { return }
                await self?.refreshVolumesNow()
                try? await clock.sleep(until: next)
            }
        }
    }

    func refreshVolumes() {
        volumeTick = 0
        Task { await refreshVolumesNow() }
    }

    private func refreshVolumesNow() async {
        guard !refreshingVolumes else { return }
        refreshingVolumes = true
        let request = UUID()
        volumeRequest = request
        defer {
            refreshingVolumes = false
            if volumeError == nil, let volume = selectedVolume, let bytes = volume.availableBytes {
                if Date().timeIntervalSince(capacitySamples[volume.id]?.last?.date ?? .distantPast) >= 5 {
                    var samples = capacitySamples[volume.id] ?? []
                    samples.append(CapacitySample(date: Date(), available: bytes))
                    capacitySamples[volume.id] = Array(samples.suffix(120))
                }
            }
        }
        do {
            let fullRefresh = volumeTick % 10 == 0 || volumes.isEmpty
            let target = selectedVolumeID
            volumeTick &+= 1
            if !fullRefresh, let target {
                // The displayed volume is measured every second; the mount list every ten.
                let refreshed = try await Task.detached(priority: .utility) {
                    try VolumeService().volume(containing: target)
                }.value
                guard request == volumeRequest else { return }
                if let index = volumes.firstIndex(where: { $0.id == refreshed.id }), volumes[index] != refreshed {
                    volumes[index] = refreshed
                    if lastLoggedAvailable != refreshed.availableBytes {
                        lastLoggedAvailable = refreshed.availableBytes
                        Self.log.debug("Volume \(refreshed.name, privacy: .public) available bytes: \(refreshed.availableBytes ?? -1)")
                    }
                }
                volumeError = nil
                return
            }
            let updated = try await Task.detached(priority: .utility) {
                try VolumeService().mountedVolumes()
            }.value
            guard request == volumeRequest else { return }
            if updated != volumes { volumes = updated }
            synchronizeInventory()
            if !updated.contains(where: { $0.id == selectedVolumeID }) {
                selectedVolumeID = updated.first?.id
            }
            volumeError = nil
        } catch {
            guard request == volumeRequest else { return }
            volumeError = "Capacity reading is stale. " + error.localizedDescription
        }
    }

    /// Called by the view when the app gains or loses focus. Reduces background work when inactive.
    func setApplicationActive(_ active: Bool) {
        guard isApplicationActive != active else { return }
        isApplicationActive = active
        for worker in mountWorkers.values { worker.setApplicationActive(active) }
        if active, !pendingPaths.isEmpty { scheduleIncrementalUpdate() }
    }

    // MARK: - Initial automatic scan

    /// Start with the last valid user folder, or the dynamically resolved account home.
    /// A stale system/firmlink path from an earlier build is rejected instead of becoming an
    /// empty scan scope for every later launch.
    func startAutomatically() {
        guard !didStartInitialScan else { return }
        didStartInitialScan = true
        guard activeFolder == nil, scanTask == nil, result == nil else { return }
        let stored = defaults.string(forKey: Self.lastFolderKey)
        let validation = rootResolver.validateStoredRoot(stored)
        if let validated = validation.url {
            Self.log.info("Resuming validated scan root \(validated.path, privacy: .public)")
            scan(folder: validated)
            startApplicationsDiscovery()
            return
        }
        if stored != nil {
            defaults.removeObject(forKey: Self.lastFolderKey)
            Self.log.error("Rejected saved scan root: \(validation.rejection ?? "unavailable", privacy: .public)")
        }
        let home = rootResolver.defaultRoot
        Self.log.info("Starting automatic scan of account home \(home.path, privacy: .public)")
        scan(folder: home)
        startApplicationsDiscovery()
        if let rejection = validation.rejection {
            scanMessage = "The saved scan folder was not a valid user location. \(rejection) Started with \(home.path) instead."
        }
    }

    /// Measures installed application bundles once at launch without changing the browse scope.
    /// This is a separate inventory root and is deduplicated in the measured breakdown.
    private func startApplicationsDiscovery(force: Bool = false) {
        guard manageVolumes, !inventoryWorker else { return }
        if !force, applicationScanTask != nil || applicationsResult != nil { return }
        let root = URL(fileURLWithPath: "/Applications", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        applicationsLoading = true
        applicationsError = nil
        applicationScanTask = Task { [weak self] in
            defer {
                self?.applicationsLoading = false
                self?.applicationScanTask = nil
            }
            do {
                let scanned = try await FullScanQueue.shared.scan(
                    root, options: ScanOptions(largestFileLimit: 200, directoryLimit: 50_000,
                                               issueLimit: 40, minimumRetainedDepth: 1))
                try Task.checkCancellation()
                self?.applicationsResult = scanned
                self?.inventoryRevision &+= 1
                Self.log.info("Applications inventory finished: \(scanned.root.fileCount) files, \(scanned.root.allocatedBytes) allocated, \(scanned.issueCount) issues")
            } catch is CancellationError {
                return
            } catch {
                self?.applicationsError = "Applications could not be measured. " + error.localizedDescription
            }
        }
    }

    // MARK: - Folder scanning

    func chooseFolder() { chooseFolder(startingAt: nil) }

    func chooseVolumeFolder(_ mount: URL) { chooseFolder(startingAt: mount) }

    private func chooseFolder(startingAt folder: URL?) {
        guard !isBusy else { return }
        choosingFolder = true
        let panel = NSOpenPanel()
        panel.directoryURL = folder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.prompt = "Scan Folder"
        panel.message = "Choose the folder to scan and monitor. macOS controls access to protected locations."
        let finished: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.choosingFolder = false
            if response == .OK, let url = panel.url {
                self.scan(folder: url)
            } else if self.result == nil {
                self.scanMessage = "No folder selected. Scanning starts when you choose a folder."
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finished)
        } else {
            panel.begin(completionHandler: finished)
        }
    }

    func scan(folder: URL) {
        guard scanTask == nil else { return }
        initialRetry?.cancel()
        initialRetry = nil
        lastReconciliationAttempt = nil
        let previousReconcile = reconcileTask
        cancelReconciliation()
        let previousIncremental = incrementalTask
        previousIncremental?.cancel()
        debounceTask?.cancel()
        debounceTask = nil
        recommendationsGeneration += 1
        stopMonitoring()
        pendingPaths.removeAll()
        pendingChangeCount = 0
        hasIncrementalChanges = false
        monitoringError = nil

        Self.log.info("Starting full scan of \(folder.path, privacy: .public)")
        activeFolder = folder
        progress = nil
        scanMessage = nil
        isCancelling = false
        scanTask = Task { [self] in
            await previousReconcile?.value
            await previousIncremental?.value
            await startMonitoring(root: folder)
            defer {
                preparingPreview = false
                activeFolder = nil
                progress = nil
                isCancelling = false
                scanTask = nil
                synchronizeInventory()
                drainPendingWork()
            }

            let (updates, continuation) = AsyncStream<ScanProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let displayUpdates = Task {
                for await update in updates {
                    guard !Task.isCancelled else { break }
                    progress = update
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            defer {
                continuation.finish()
                displayUpdates.cancel()
            }
            do {
                let completed = try await FullScanQueue.shared.scan(folder, options: scanOptions) { continuation.yield($0) }
                try Task.checkCancellation()
                preparingPreview = true
                let matches = await Self.recommendations(for: completed)
                try Task.checkCancellation()
                recommendations = matches
                let policy = RecoverabilityPolicy()
                let eligible = matches.filter { policy.assess($0).isDeletable }
                let recoverable = eligible.reduce(Int64(0)) { $0 + max(0, $1.allocatedBytes) }
                Self.log.info("Cleanup candidates: \(matches.count) measured, \(eligible.count) eligible, \(recoverable) allocated estimated")
                result = completed
                lastCompletedAt = completed.completedAt
                lastVerifiedAt = completed.completedAt
                lastIncrementalAt = nil
                hasIncrementalChanges = false
                Self.log.info("Full scan finished: \(completed.root.fileCount) files, \(completed.root.logicalBytes) logical, \(completed.root.allocatedBytes) allocated, issues \(completed.issueCount)")
                if !inventoryWorker { defaults.set(completed.completedAt, forKey: Self.lastScanKey) }
                if !inventoryWorker && defaults.string(forKey: Self.lastFolderKey) != folder.path {
                    defaults.set(folder.path, forKey: Self.lastFolderKey)
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    scanMessage = "Cancelled the scan of \(folder.path)."
                } else {
                    let cause = error as NSError
                    let permissionCodes = [Int(POSIXErrorCode.EACCES.rawValue), Int(POSIXErrorCode.EPERM.rawValue)]
                    let guidance = cause.domain == NSPOSIXErrorDomain && permissionCodes.contains(cause.code)
                        ? " Review file access in System Settings under Privacy & Security, or choose another folder."
                        : ""
                    scanMessage = error.localizedDescription + guidance
                }
                stopMonitoring()
                if let existing = result {
                    await startMonitoring(root: existing.root.url)
                    reconcileSoon = true
                } else if !Task.isCancelled {
                    initialRetry = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                        guard !Task.isCancelled else { return }
                        self?.scan(folder: folder)
                    }
                }
            }
        }
    }

    private static func recommendations(for scan: ScanResult) async -> [CleanupRecommendation] {
        await Task.detached(priority: .utility) {
            let registry = CleanupRuleRegistry()
            let initial = registry.recommendations(for: scan)
            let activity = (try? StorageActivitySnapshot.capture(candidates: initial.map(\.target))) ?? .unknown
            return registry.recommendations(for: scan, activity: activity)
        }.value
    }

    // MARK: - Monitoring

    private func startMonitoring(root: URL) async {
        eventMonitor?.stop()
        eventMonitor = nil
        monitoredRoot = root
        monitoringState = .starting
        let generation = UUID()
        watchID = generation
        if scopedRoot == nil, root.startAccessingSecurityScopedResource() { scopedRoot = root }
        let monitor = monitorFactory(root) { [weak self] changes in
            Task { @MainActor [weak self] in
                guard let self, self.watchID == generation else { return }
                self.receive(changes)
            }
        }
        startReconciliationLoop()
        do {
            try await Task.detached(priority: .utility) { try monitor.start() }.value
            guard watchID == generation else { monitor.stop(); return }
            eventMonitor = monitor
            monitoringState = .active
            monitoringError = nil
            Self.log.info("Monitoring started for \(root.path, privacy: .public)")
        } catch {
            guard watchID == generation else { return }
            monitoringState = .unavailable(error.localizedDescription)
            monitoringError = error.localizedDescription
            Self.log.error("Monitoring unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopMonitoring() {
        watchID = UUID()
        restartStream = false
        scopedRoot?.stopAccessingSecurityScopedResource()
        scopedRoot = nil
        eventMonitor?.stop()
        eventMonitor = nil
        monitoredRoot = nil
        monitoringState = .idle
        reconciliationLoop?.cancel()
        reconciliationLoop = nil
    }

    private func receive(_ changes: [FileSystemChange]) {
        guard let root = monitoredRoot else { return }
        let prefix = root.path == "/" ? "/" : root.path + "/"
        for change in changes {
            if change.requiresFullRescan {
                reconcileSoon = true
                if change.isRootChanged { restartStream = true }
            } else if change.path == root.path || change.path.hasPrefix(prefix) {
                if pendingPaths.count < 5_000 {
                    pendingPaths.insert(change.path)
                } else {
                    reconcileSoon = true
                }
            }
        }
        pendingChangeCount = pendingPaths.count
        drainPendingWork()
    }

    private func drainPendingWork() {
        guard scanTask == nil, reconcileTask == nil, incrementalTask == nil, result != nil else { return }
        if reconcileSoon {
            scheduleReconciliation(immediate: true)
        } else if !pendingPaths.isEmpty {
            scheduleIncrementalUpdate()
        }
    }

    // Schedule from the first event. Continuous writes cannot postpone a batch indefinitely.
    private func scheduleIncrementalUpdate() {
        guard debounceTask == nil else { return }
        let cooldown: TimeInterval = reducedActivity ? 8 : 3
        let elapsed = lastIncrementalBatchAt.map { Date().timeIntervalSince($0) } ?? cooldown
        let delay = max(reducedActivity ? 2.5 : 0.7, cooldown - elapsed)
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.applyIncrementalChanges()
        }
    }

    private func applyIncrementalChanges() {
        guard incrementalTask == nil, scanTask == nil, reconcileTask == nil,
              let current = result, !pendingPaths.isEmpty else { return }
        let options = scanOptions
        let paths = pendingPaths
        pendingPaths.removeAll()
        pendingChangeCount = 0
        lastIncrementalBatchAt = Date()
        hasIncrementalChanges = true

        incrementalTask = Task {
            defer {
                incrementalTask = nil
                if !Task.isCancelled { drainPendingWork() }
            }
            let worker = Task.detached(priority: .utility) {
                var latest = current
                var anchors = Set<URL>()
                for path in paths {
                    try Task.checkCancellation()
                    let parent = path == current.root.url.path ? path :
                        URL(fileURLWithPath: path).deletingLastPathComponent().path
                    if let folder = current.deepestDirectory(containing: parent) { anchors.insert(folder.url) }
                }
                // Direct refresh preserves existing children, so nested anchors must also run.
                for anchor in anchors.sorted(by: { $0.path.count < $1.path.count }) {
                    try Task.checkCancellation()
                    guard latest.deepestDirectory(containing: anchor.path)?.url.path == anchor.path else { continue }
                    latest = try await StorageScanner().refreshDirectory(at: anchor, in: latest, options: options)
                }
                return latest
            }
            do {
                let updated = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                result = updated
                lastIncrementalAt = Date()
                recomputeRecommendations()
            } catch {
                if !Task.isCancelled {
                    monitoringError = "Some changes could not be measured. " + error.localizedDescription
                    reconcileSoon = true
                }
            }
        }
    }

    private func recomputeRecommendations() {
        guard let scan = result else { recommendations = []; return }
        if recommendationsRunning {
            recommendationsPending = true
            recommendationsGeneration += 1
            return
        }
        recommendationsRunning = true
        recommendationsGeneration += 1
        let generation = recommendationsGeneration
        Task { [weak self] in
            let matches = await Self.recommendations(for: scan)
            guard let self else { return }
            if generation == self.recommendationsGeneration { self.recommendations = matches }
            self.recommendationsRunning = false
            if self.recommendationsPending {
                self.recommendationsPending = false
                self.recomputeRecommendations()
            }
        }
    }

    // MARK: - Reconciliation

    private func startReconciliationLoop() {
        reconciliationLoop?.cancel()
        reconciliationLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let tick = self?.reconciliationTick else { return }
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.scheduleReconciliation(immediate: false)
            }
        }
    }

    private func scheduleReconciliation(immediate: Bool) {
        if immediate {
            reconcileSoon = true
            hasIncrementalChanges = true
        }
        guard reconcileTask == nil, result != nil, scanTask == nil,
              activeFolder == nil, cleanupActivity == nil, confirmation == nil else { return }
        let interval = reconciliationInterval * (reducedActivity ? 3 : 1)
        let last = lastVerifiedAt ?? .distantPast
        guard reconcileSoon || Date().timeIntervalSince(last) >= interval else { return }

        reconcileSoon = true
        guard incrementalTask == nil else { return }
        // Repeated stream loss or a disconnected mount may persist across attempts.
        if let attempt = lastReconciliationAttempt,
           Date().timeIntervalSince(attempt) < min(30, reconciliationInterval) { return }
        lastReconciliationAttempt = Date()
        reconcileSoon = false
        pendingPaths.removeAll()
        pendingChangeCount = 0
        isReconciling = true
        let root = result?.root.url
        reconcileTask = Task { [weak self] in
            guard let self, let root else { return }
            var succeeded = false
            defer {
                self.isReconciling = false
                self.reconcileTask = nil
                if succeeded { self.drainPendingWork() }
            }
            do {
                if self.eventMonitor == nil || self.restartStream {
                    self.restartStream = false
                    await self.startMonitoring(root: root)
                }
                try Task.checkCancellation()
                Self.log.info("Reconciliation started")
                let refreshed = try await FullScanQueue.shared.scan(root, options: self.scanOptions)
                try Task.checkCancellation()
                guard self.scanTask == nil else { return }
                Self.log.info("Reconciliation finished: \(refreshed.root.fileCount) files")
                self.result = refreshed
                self.lastVerifiedAt = refreshed.completedAt
                self.lastCompletedAt = refreshed.completedAt
                self.hasIncrementalChanges = false
                if self.eventMonitor != nil { self.monitoringError = nil }
                succeeded = true
                self.recomputeRecommendations()
            } catch is CancellationError {
                // A user-initiated scan takes precedence.
            } catch {
                self.hasIncrementalChanges = true
                self.monitoringError = "Automatic verification failed: " + error.localizedDescription
                self.reconcileSoon = true
            }
        }
    }

    private func cancelReconciliation() {
        reconcileSoon = false
        reconcileTask?.cancel()
        reconcileTask = nil
        isReconciling = false
    }

    // MARK: - Cleanup

    func chooseFileForTrash() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.prompt = "Review File"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Choose a file directly in Downloads or Desktop, or a log under Library/Logs. You’ll review the file before moving it to Trash."
        choosingFolder = true
        panel.begin { response in
            self.choosingFolder = false
            if response == .OK, let url = panel.url { self.reviewSelection([url]) }
        }
    }

    /// Reviewing always routes through the recoverability policy, which decides the allowed
    /// deletion modes and whether a separate typed high-risk confirmation is required.
    func reviewTrash(_ url: URL) {
        reviewSelection([url])
    }

    func reviewPackage(_ match: CleanupRecommendation) {
        prepareCleanup(action: "Clean Package Cache", target: match.target) {
            let ticket = try PackageCleanup.prepare(match)
            return CleanupConfirmation(action: "Clean Package Cache", target: match.target,
                explanation: ticket.summary + "\n\n" + match.consequences, operation: .package(ticket))
        }
    }

    /// Bulk verified cleanup. Every selected location must still have an installed official
    /// cleanup mechanism; otherwise it is excluded and the remaining resources are prepared.
    func reviewPackages(_ matches: [CleanupRecommendation]) {
        let policy = RecoverabilityPolicy()
        let eligible = matches.filter { policy.assess($0).isDeletable && PackageCleanup.supports($0) }
        guard let first = eligible.first else { return }
        prepareCleanup(action: "Clean Selected Caches", target: first.target) {
            let tickets = try eligible.map(PackageCleanup.prepare)
            let total = tickets.reduce(Int64(0)) { $0 + $1.estimatedBytes }
            let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            var lines = ["Use the installed, official cleanup mechanisms on \(tickets.count) selected cache location(s), estimated \(totalText) allocated."]
            lines.append("")
            lines.append("Resources:")
            for match in eligible {
                let assessment = policy.assess(match)
                lines.append("• \(match.target.path) — \(ByteCountFormatter.string(fromByteCount: match.allocatedBytes, countStyle: .file)) — \(assessment.evidence)")
            }
            lines.append("")
            lines.append("Each tool revalidates its cache. Associated project data is not removed. Future builds may download packages again. Partial failures are reported after all selected cleanups run.")
            return CleanupConfirmation(action: "Clean \(tickets.count) Caches", target: first.target,
                                       explanation: lines.joined(separator: "\n"), operation: .packageBatch(tickets))
        }
    }

    private func prepareCleanup(action: String, target: URL,
                                prepare: @escaping @Sendable () throws -> CleanupConfirmation) {
        guard !isBusy else { return }
        cleanupActivity = "Checking the selected item…"
        Task {
            defer { cleanupActivity = nil }
            do { confirmation = try await Task.detached(priority: .userInitiated, operation: prepare).value }
            catch {
                record(CleanupRecord(id: UUID(), date: Date(), action: action, path: target.path,
                                     status: "Blocked", detail: error.localizedDescription))
                scanMessage = error.localizedDescription
                page = .history
            }
        }
    }

    func confirmCleanup(_ request: CleanupConfirmation) {
        guard confirmation?.id == request.id, cleanupActivity == nil, activeFolder == nil else { return }
        confirmation = nil
        cleanupActivity = request.action + "…"
        let folder = result?.root.url
        var entry = CleanupRecord(id: request.id, date: Date(), action: request.action, path: request.target.path,
                                  status: "Started", detail: "Final outcome has not been recorded.")
        record(entry)
        Task {
            do {
                entry.detail = try await Task.detached(priority: .userInitiated) {
                    switch request.operation {
                    case .trash(let ticket): return try TrashExecutor.execute(ticket)
                    case .package(let ticket): return try PackageCleanup.execute(ticket)
                    case .packageBatch(let tickets): return try PackageCleanup.executeBatch(tickets)
                    }
                }.value
                entry.status = "Completed"
            } catch {
                entry.status = "Failed"
                entry.detail = error.localizedDescription
            }
            record(entry)
            cleanupActivity = nil
            page = .history
            refreshVolumes()
            if let folder {
                result = nil
                recommendations = []
                scan(folder: folder)
            }
        }
    }

    func recordOperation(action: String, path: String, status: String, detail: String) {
        finishSelection(CleanupRecord(id: UUID(), date: Date(), action: action, path: path, status: status, detail: detail))
    }

    func finishSelection(_ entry: CleanupRecord) {
        record(entry)
        if entry.path == "/Applications" || entry.path.hasPrefix("/Applications/") {
            startApplicationsDiscovery(force: true)
        }
        // Batch results and resource managers can complete before FSEvents publishes its batch.
        let url = URL(fileURLWithPath: entry.path)
        for owner in [self] + Array(mountWorkers.values) {
            guard let root = owner.monitoredRoot else { continue }
            if entry.path.hasPrefix("/"), url.path == root.path || url.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") {
                owner.receive([FileSystemChange(path: url.path, flags: 0)])
            }
        }
        refreshVolumes()
        inventoryRevision &+= 1
    }

    func reviewSelection(_ urls: [URL]) {
        guard !urls.isEmpty, confirmation == nil, deletionSelection == nil, cleanupActivity == nil else { return }
        deletionSelection = SelectionRequest(urls: Array(Set(urls)).sorted { $0.path < $1.path })
    }

    func setMonitorAll(_ enabled: Bool) {
        monitorAll = enabled
        defaults.set(enabled, forKey: "inventory.allMounts")
        synchronizeInventory()
    }

    func setVolume(_ url: URL, enabled: Bool) {
        if enabled { disabledMounts.remove(url.path) } else { disabledMounts.insert(url.path) }
        defaults.set(Array(disabledMounts), forKey: "inventory.disabledMounts")
        synchronizeInventory()
    }

    func updateExclusions(_ paths: [String]) {
        excludedFolders = Array(Set(paths)).sorted()
        defaults.set(excludedFolders, forKey: "inventory.exclusions")
        for worker in mountWorkers.values { worker.shutdown() }
        mountWorkers.removeAll()
        subscriptions.removeAll()
        if let folder = monitoredRoot {
            let previous = scanTask
            previous?.cancel()
            Task { await previous?.value; scan(folder: folder) }
        }
        synchronizeInventory()
    }

    private func shutdown() {
        initialRetry?.cancel()
        scanTask?.cancel()
        reconcileTask?.cancel()
        incrementalTask?.cancel()
        debounceTask?.cancel()
        stopMonitoring()
    }

    private func synchronizeInventory() {
        guard manageVolumes, didStartInitialScan else { return }
        // A primary scan is also useful by itself when the user disables additional mounts.
        let primary = (activeFolder ?? result?.root.url ?? defaultRoot).standardizedFileURL
        var roots = Set(volumes.filter { $0.automaticallyInventoried && !disabledMounts.contains($0.id.path) }
            .map { $0.id.standardizedFileURL })
        roots.remove(primary)
        if !monitorAll { roots.removeAll() }
        for url in Array(mountWorkers.keys) where !roots.contains(url) {
            subscriptions[url] = nil
            mountWorkers.removeValue(forKey: url)?.shutdown()
        }
        for url in roots.sorted(by: { $0.path < $1.path }) where mountWorkers[url] == nil {
            let worker = StorageModel(defaults: defaults, defaultRoot: url, inventoryWorker: true,
                                      reconciliationInterval: 3600, reconciliationTick: 60)
            worker.setApplicationActive(isApplicationActive)
            // Resolve firmlink aliases so an explicitly excluded folder stays excluded on Data.
            // Privacy-protected home locations are excluded from automatic inventory so a launch
            // never triggers repeated macOS permission prompts.
            worker.excludedFolders = InventoryPaths.exclusions(excludedFolders, for: url) +
                InventoryPaths.exclusions(Self.protectedHomePaths, for: url)
            mountWorkers[url] = worker
            subscriptions[url] = worker.objectWillChange
                .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.inventoryRevision &+= 1 }
            worker.scan(folder: url)
            inventoryRevision &+= 1
        }
    }

    /// Locations macOS protects through privacy prompts. They are scanned only when explicitly chosen.
    private static var protectedHomePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
                "Library/Containers", "Library/Group Containers", "Library/Safari", "Library/Mail",
                "Library/Messages", "Library/CloudStorage", "Library/Application Support/com.apple.TCC", ".Trash"]
            .map { home.appendingPathComponent($0).path }
    }

    private func record(_ entry: CleanupRecord) {
        history.removeAll { $0.id == entry.id }
        history.insert(entry, at: 0)
        do { defaults.set(try JSONEncoder().encode(history), forKey: historyKey) }
        catch { scanMessage = "Could not save the cleanup history. " + error.localizedDescription }
    }

    func cancelScan() {
        guard scanTask != nil else { return }
        isCancelling = true
        scanTask?.cancel()
    }

    func reveal(_ item: URL) {
        showFinderError = !NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
    }

    func openContainingFolder(of item: URL) {
        showFinderError = !NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.deletingLastPathComponent().path)
    }
}

extension URL {
    var displayName: String {
        lastPathComponent.isEmpty ? path : lastPathComponent
    }
}

enum StorageFormat {
    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "Unavailable" }
        if bytes == 0 { return "0 bytes" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}
