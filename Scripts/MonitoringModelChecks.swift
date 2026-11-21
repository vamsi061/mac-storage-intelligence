import Combine
import Darwin
import Foundation
import StorageCore
@testable import StorageApp

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message) }
}

private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

// The switch suppresses actual FSEvents delivery for one mutation so that only periodic
// verification can discover it. The stream itself continues running.
private final class EventGate: @unchecked Sendable {
    private let lock = NSLock()
    private var suppress = false
    private var dropped = 0

    func close() { lock.withLock { suppress = true } }
    var droppedCount: Int { lock.withLock { dropped } }
    func allow(_ changes: [FileSystemChange]) -> Bool {
        lock.withLock {
            if suppress { dropped += changes.count }
            return !suppress
        }
    }
}

private struct Sample {
    let time: TimeInterval
    let cpu: Double
    let rss, read, written: UInt64

    init() throws {
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
            }
        }
        try require(status == 0, "proc_pid_rusage failed: \(errno)")
        time = now
        var cpuUsage = rusage()
        try require(getrusage(RUSAGE_SELF, &cpuUsage) == 0, "getrusage failed")
        func seconds(_ time: timeval) -> Double {
            Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
        }
        cpu = seconds(cpuUsage.ru_utime) + seconds(cpuUsage.ru_stime)
        rss = usage.ri_resident_size
        read = usage.ri_diskio_bytesread
        written = usage.ri_diskio_byteswritten
    }
}

private func report(_ phase: String, _ samples: [Sample]) throws {
    guard let start = samples.first, let end = samples.last, end.time > start.time else {
        throw Failure("Insufficient samples for \(phase)")
    }
    let duration = end.time - start.time
    let peakCPU = zip(samples, samples.dropFirst()).map {
        ($1.cpu - $0.cpu) * 100 / ($1.time - $0.time)
    }.max() ?? 0
    let peakRSS = Double(samples.map(\.rss).max() ?? 0) / 1_048_576
    print(String(format: "%@ samples=%d duration=%.2fs CPU_mean=%.2f%% CPU_peak_sample=%.2f%% RSS_peak=%.1fMiB disk_read=%lluB disk_written=%lluB",
                 phase, samples.count, duration, (end.cpu - start.cpu) * 100 / duration,
                 peakCPU, peakRSS, end.read - start.read, end.written - start.written))
}

@MainActor
private func until(_ message: @autoclosure () -> String, timeout: Double = 12, _ predicate: () -> Bool) async throws {
    let end = now + timeout
    while !predicate() {
        if now >= end { throw Failure("Timed out: " + message()) }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

// Run fixture mutations in a separate process so they do not count as the model's disk I/O.
private func mutate(_ root: URL, _ operation: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--write-fixture", root.path, operation]
    try process.run()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "Fixture writer failed: " + operation)
}

private func writeFixture(_ root: URL, _ operation: String) throws {
    let fm = FileManager.default
    func file(_ path: String) -> URL { root.appendingPathComponent(path) }
    func write(_ path: String, count: Int) throws {
        try Data(repeating: 65, count: count).write(to: file(path))
    }
    switch operation {
    case "seed":
        for index in 0..<16 {
            let dir = "branch-\(index)/sub/deep"
            try fm.createDirectory(at: file(dir), withIntermediateDirectories: true)
            for item in 0..<128 { try write("\(dir)/\(item)", count: 32) }
        }
    case "create": try write("branch-0/sub/deep/observed", count: 8_192)
    case "modify": try write("branch-0/sub/deep/observed", count: 16_384)
    case "move": try fm.moveItem(at: file("branch-0/sub/deep/observed"), to: file("branch-1/sub/deep/moved"))
    case "delete": try fm.removeItem(at: file("branch-1/sub/deep/moved"))
    case "root": try write("top", count: 4_096)
    case "missed": try write("branch-2/sub/deep/missed", count: 2_048)
    default: throw Failure("Unexpected fixture operation")
    }
}

@main
private enum MonitoringChecks {
    static func main() async {
        do {
            let args = CommandLine.arguments
            if args.count == 4, args[1] == "--write-fixture" {
                try writeFixture(URL(fileURLWithPath: args[2]), args[3])
            } else {
                try require(args.count == 2, "Run Scripts/test-monitoring-model.sh")
                try await run(URL(fileURLWithPath: args[1]))
            }
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func run(_ temp: URL) async throws {
        let root = temp.appendingPathComponent("fixture", isDirectory: true).resolvingSymlinksInPath()
        try mutate(root, "seed")
        let suite = "local.msi.fixture." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure("UserDefaults suite unavailable") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = EventGate()
        var deliverEvent: (@Sendable ([FileSystemChange]) -> Void)?
        var injectDuringVerification = false
        var queuedDuringVerification = false
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let period: Double = lowPower ? 75 : 35
        let model = StorageModel(defaults: defaults, defaultRoot: root,
                                 reconciliationInterval: lowPower ? period / 3 : period, reconciliationTick: 1,
                                 monitorFactory: { url, receive in
            deliverEvent = receive
            return FileSystemEventMonitor(root: url) { changes in
                if gate.allow(changes) { receive(changes) }
            }
        })
        var subscriptions = Set<AnyCancellable>()
        var capacityTicks = [TimeInterval]()
        var validCapacitySamples = 0
        var reconciliations = 0
        var overlaps = 0
        model.$refreshingVolumes.dropFirst().sink { refreshing in
            guard !refreshing else { return }
            capacityTicks.append(now)
            if model.volumeError == nil, let volume = model.selectedVolume,
               let total = volume.totalBytes, total > 0,
               let free = volume.availableBytes, (0...total).contains(free),
               let used = volume.usedBytes, (0...total).contains(used) {
                validCapacitySamples += 1
            }
        }.store(in: &subscriptions)
        model.$isReconciling.sink {
            if $0 {
                reconciliations += 1
                if injectDuringVerification {
                    injectDuringVerification = false
                    let path = root.appendingPathComponent("branch-3/sub/deep/0").path
                    deliverEvent?([FileSystemChange(path: path, flags: 0)])
                }
                if model.incrementalUpdateInProgress || model.activeFolder != nil { overlaps += 1 }
            }
        }.store(in: &subscriptions)
        model.$pendingChangeCount.sink { count in
            if count > 0 && model.isReconciling { queuedDuringVerification = true }
        }.store(in: &subscriptions)
        model.$lastIncrementalAt.dropFirst().sink { date in
            if date != nil && model.isReconciling { overlaps += 1 }
        }.store(in: &subscriptions)
        var samples = [try Sample()]
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 500_000_000)
                samples.append(try Sample())
            }
        }
        defer { sampler.cancel() }
        model.startAutomatically()
        try await until("automatic scan and healthy monitoring (\(model.monitoringState), count=\(model.result?.root.fileCount ?? -1), scan=\(model.scanMessage ?? "none"), monitor=\(model.monitoringError ?? "none"))") {
            model.result?.root.fileCount == 2048 && model.monitoringState == .active && model.activeFolder == nil
        }
        let expectedBytes: Int64 = 2048 * 32
        try require(model.result?.root.logicalBytes == expectedBytes, "Incorrect launch total")
        let idleStart = samples.count
        try await Task.sleep(nanoseconds: 8_500_000_000)
        try report("idle", Array(samples.dropFirst(idleStart)))
        try require(reconciliations == 0 && model.lastIncrementalAt == nil, "Idle period triggered folder measurement")
        try require(validCapacitySamples == capacityTicks.count, "Volume refresh returned missing or invalid capacity values")
        let idleTicks = capacityTicks
        let gaps = zip(idleTicks, idleTicks.dropFirst()).map { $1 - $0 }
        try require(gaps.count >= 6 && (gaps.max() ?? 0) < 2.5, "Capacity polling cadence was interrupted")
        print(String(format: "valid capacity samples=%d mean_gap=%.2fs max_gap=%.2fs", idleTicks.count,
                     gaps.reduce(0, +) / Double(gaps.count), gaps.max() ?? 0))
        let activeStart = samples.count - 1
        for (operation, count, delta) in [("create", 2049, 8192), ("modify", 2049, 16384),
                                          ("move", 2049, 16384), ("delete", 2048, 0), ("root", 2049, 4096)] {
            let start = now
            try mutate(root, operation)
            try await until(operation) {
                guard let result = model.result, result.root.fileCount == count,
                      result.root.logicalBytes == expectedBytes + Int64(delta) else { return false }
                if operation == "move" {
                    return result.largestFiles.first?.url.lastPathComponent == "moved" &&
                        result.deepestDirectory(containing: root.appendingPathComponent("branch-0/sub/deep").path)?.fileCount == 128
                }
                return true
            }
            print(String(format: "%@ reflected in %.2fs", operation, now - start))
        }
        try report("file activity", Array(samples.dropFirst(activeStart)))
        try require(model.lastIncrementalAt != nil, "No subtree update observed")
        try require(reconciliations == 0, "Normal file changes caused a full verification")
        try await until("completion of root change") { !model.isReconciling && !model.incrementalUpdateInProgress }
        gate.close()
        injectDuringVerification = true
        let incrementalBeforeLoss = model.lastIncrementalAt
        let verifiedBeforeLoss = model.lastVerifiedAt
        try mutate(root, "missed")
        try await until("real event suppressed", timeout: 5) { gate.droppedCount > 0 }
        try require(model.result?.root.fileCount == 2049, "Suppressed mutation unexpectedly represented before verification")
        let repairStart = now
        try await until("periodic repair of missed change", timeout: period + 6) {
            model.lastVerifiedAt != verifiedBeforeLoss && model.result?.root.fileCount == 2050 &&
            model.result?.root.logicalBytes == expectedBytes + 6144 && !model.isReconciling
        }
        let repairTime = now - repairStart
        try await until("queued event applied after full verification") {
            queuedDuringVerification && model.lastIncrementalAt != incrementalBeforeLoss && !model.incrementalUpdateInProgress
        }
        try require(overlaps == 0, "Observed overlapping incremental and full measurements")
        let stable = model.result?.root
        try require(stable?.url.standardizedFileURL == root.standardizedFileURL, "Unexpected root")
        print(String(format: "missed change repaired in %.2fs; dropped events=%d; reconciliations=%d; queued-during-verification event applied; observed overlaps=%d",
                     repairTime, gate.droppedCount, reconciliations, overlaps))
        try report("whole run", samples + [try Sample()])

        // Isolated launch profile: the old firmlink path is persisted, but the model must
        // reject it and scan the injected account home instead.
        let launchSuite = "local.msi.stale-launch." + UUID().uuidString
        guard let launchDefaults = UserDefaults(suiteName: launchSuite) else { throw Failure("Launch-defaults suite unavailable") }
        defer { launchDefaults.removePersistentDomain(forName: launchSuite) }
        launchDefaults.set("/System/Volumes/Data/home", forKey: "storage.lastScannedFolder")
        let launchModel = StorageModel(defaults: launchDefaults, defaultRoot: root, inventoryWorker: false,
                                       reconciliationInterval: 3600, reconciliationTick: 3600)
        launchModel.startAutomatically()
        try await until("isolated launch profile scan", timeout: 20) {
            launchModel.result?.root.url.standardizedFileURL == root.standardizedFileURL &&
            launchModel.activeFolder == nil
        }
        try require(launchModel.result?.root.fileCount == 2050, "Stale profile did not measure the account home fixture")
        try require(launchDefaults.string(forKey: "storage.lastScannedFolder") == root.path,
                    "Stale launch path was not replaced by the validated home")
        print("isolated stale-profile launch scanned \(launchModel.result?.root.fileCount ?? 0) files under the injected home")

        // A completed deletion must update the measured result and expose the outcome on the
        // dashboard model without requiring a manual refresh.
        let deleted = root.appendingPathComponent("branch-0/sub/deep/0")
        try FileManager.default.removeItem(at: deleted)
        launchModel.finishSelection(CleanupRecord(id: UUID(), date: Date(), action: "Delete",
                                                  path: deleted.path, status: "Completed",
                                                  detail: "Observed source-volume available-space change: 32 bytes."))
        try await until("post-deletion dashboard refresh", timeout: 10) {
            launchModel.result?.root.fileCount == 2049
        }
        try require(launchModel.history.first?.status == "Completed", "Deletion outcome was not written to history")
        print("post-deletion rescan updated measured files to 2049 and exposed the completed outcome")
        withExtendedLifetime(subscriptions) {}
    }
}
