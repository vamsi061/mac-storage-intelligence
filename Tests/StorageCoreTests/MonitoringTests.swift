import CoreServices
import Foundation

#if !STORAGE_FIXTURE_RUNNER
@testable import StorageCore
import XCTest
#endif

private struct MonitoringFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw MonitoringFailure(description: message) }
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FileSystemChange] = []

    func append(_ changes: [FileSystemChange]) {
        lock.withLock { events.append(contentsOf: changes) }
    }

    var count: Int { lock.withLock { events.count } }

    func observations(after index: Int) -> [FileSystemChange] {
        lock.withLock { Array(events.dropFirst(index)) }
    }
}

private func waitForPath(_ path: String, after index: Int, in collector: EventCollector,
                         matching predicate: (FileSystemChange) -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if collector.observations(after: index).contains(where: { $0.path == path && predicate($0) }) {
            return
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let observed = collector.observations(after: index).prefix(12).map { "\($0.path) (\($0.flags))" }
    throw MonitoringFailure(description: "Missing fresh FSEvents flags at \(path). Saw: \(observed)")
}

enum MonitoringChecks {
    static func incrementalMerge(_ root: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        func write(_ relative: String, _ bytes: Int) throws {
            try Data(repeating: 0x42, count: bytes).write(to: root.appendingPathComponent(relative))
        }
        try write("top", 100)
        try write("sub/a", 200)
        try write("sub/deep/b", 300)

        var result = try await StorageScanner().scan(root: root)
        try expect(result.root.fileCount == 3, "Initial scan lost files")
        try expect(result.root.logicalBytes == 600, "Initial scan totals are wrong")

        // Creation inside a deeply nested directory.
        try write("sub/deep/c", 400)
        let deep = root.appendingPathComponent("sub/deep")
        try expect(result.deepestDirectory(containing: deep.appendingPathComponent("c").path)?.url == deep,
                   "Deepest retained ancestor was not located")
        var update = try await StorageScanner().scan(root: deep)
        result = try unwrap(result.replacingSubtree(at: deep, with: update.root,
                                                    largestFiles: update.largestFiles, issues: update.issues))
        try expect(result.root.logicalBytes == 1000, "Creation was not folded into the root")
        try expect(result.root.fileCount == 4, "Creation was not counted")
        try expect(result.largestFiles.first?.url.lastPathComponent == "c", "Largest file was not refreshed")
        try expect(result.deepestDirectory(containing: deep.path)?.logicalBytes == 700,
                   "Nested folder total was not replaced")

        // Deletion in the same subtree.
        try manager.removeItem(at: root.appendingPathComponent("sub/a"))
        update = try await StorageScanner().scan(root: root.appendingPathComponent("sub"))
        result = try unwrap(result.replacingSubtree(at: root.appendingPathComponent("sub"),
                                                    with: update.root, largestFiles: update.largestFiles,
                                                    issues: update.issues))
        try expect(result.root.logicalBytes == 800 && result.root.fileCount == 3,
                   "Deletion left stale totals")

        // Rename and modification.
        try manager.moveItem(at: root.appendingPathComponent("sub/deep/b"),
                             to: root.appendingPathComponent("sub/deep/b2"))
        try write("sub/deep/b2", 350)
        update = try await StorageScanner().scan(root: deep)
        result = try unwrap(result.replacingSubtree(at: deep, with: update.root,
                                                    largestFiles: update.largestFiles, issues: update.issues))
        try expect(result.root.logicalBytes == 850, "Rename or modification was not reflected")
        try expect(result.largestFiles.contains { $0.url.lastPathComponent == "b2" },
                   "Renamed file was not merged into the retained list")
        try expect(!result.largestFiles.contains { $0.url.lastPathComponent == "b" },
                   "Old name remained in the retained list")

        // A deliberately stale merge is corrected by the next full verification.
        let stale = try unwrap(result.replacingSubtree(at: deep, with: update.root,
                                                       largestFiles: update.largestFiles, issues: update.issues))
        try expect(stale.root.logicalBytes == 850, "Repeated merge drifted totals")
        let verified = try await StorageScanner().scan(root: root)
        try expect(verified.root.logicalBytes == 850 && verified.root.fileCount == 3,
                   "Full verification did not reconcile the merged result")
    }

    static func retainedDepth(_ root: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("level/one/two"), withIntermediateDirectories: true)
        try Data([7]).write(to: root.appendingPathComponent("level/one/two/file"))

        let shallow = try await StorageScanner().scan(root: root, options: ScanOptions(directoryLimit: 1))
        try expect(shallow.root.fileCount == 1, "The limit changed aggregate totals")
        try expect(shallow.deepestDirectory(containing: root.appendingPathComponent("level/one/two/file").path)?.url
                   == shallow.root.url, "A capped scan unexpectedly retained a deep anchor")

        let retained = try await StorageScanner().scan(
            root: root, options: ScanOptions(directoryLimit: 1, minimumRetainedDepth: 3))
        let two = root.appendingPathComponent("level/one/two")
        try expect(retained.deepestDirectory(containing: two.path)?.url == two,
                   "minimumRetainedDepth did not preserve the third level")
        try expect(retained.root.fileCount == 1 && retained.root.logicalBytes == 1,
                   "Deeper retention changed totals")
    }

    static func fileSystemEvents(_ root: URL) async throws {
        let manager = FileManager.default
        // Watch through an alias and require every delivered path to use that spelling.
        let physical = root.appendingPathComponent("physical", isDirectory: true)
        try manager.createDirectory(at: physical, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try manager.createSymbolicLink(at: alias, withDestinationURL: physical)
        let watched = alias.appendingPathComponent("watched", isDirectory: true)
        let nested = watched.appendingPathComponent("one/two/three", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        let collector = EventCollector()
        let monitor = FileSystemEventMonitor(root: watched, latency: 0.15) { collector.append($0) }
        try monitor.start()
        defer { monitor.stop() }
        try expect(monitor.isRunning, "Monitor did not report a running state")

        let file = nested.appendingPathComponent("event.txt")
        var cursor = collector.count
        try Data([1]).write(to: file)
        try await waitForPath(file.path, after: cursor, in: collector, matching: \.isCreated)

        cursor = collector.count
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([2, 3]))
        try handle.close()
        try await waitForPath(file.path, after: cursor, in: collector, matching: \.isModified)

        cursor = collector.count
        let renamed = nested.appendingPathComponent("renamed.txt")
        try manager.moveItem(at: file, to: renamed)
        try await waitForPath(file.path, after: cursor, in: collector, matching: \.isRenamed)
        try await waitForPath(renamed.path, after: cursor, in: collector, matching: \.isRenamed)

        cursor = collector.count
        let moved = watched.appendingPathComponent("moved.txt")
        try manager.moveItem(at: renamed, to: moved)
        try await waitForPath(renamed.path, after: cursor, in: collector, matching: \.isRenamed)
        try await waitForPath(moved.path, after: cursor, in: collector, matching: \.isRenamed)

        cursor = collector.count
        try manager.removeItem(at: moved)
        try await waitForPath(moved.path, after: cursor, in: collector, matching: \.isRemoved)

        cursor = collector.count
        try manager.moveItem(at: watched, to: root.appendingPathComponent("relocated-root"))
        try await waitForPath(watched.path, after: cursor, in: collector) { $0.isRootChanged && $0.requiresFullRescan }

        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagKernelDropped,
                     kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagEventIdsWrapped] {
            try expect(FileSystemChange(path: watched.path, flags: UInt32(flag)).requiresFullRescan,
                       "Reconciliation flag \(flag) did not request a full scan")
        }
        try expect(!FileSystemChange(path: watched.path, flags: UInt32(kFSEventStreamEventFlagItemModified)).requiresFullRescan,
                   "Ordinary modifications were treated as dropped events")
        monitor.stop()
        try expect(!monitor.isRunning, "Monitor did not stop")
    }

    private static func unwrap(_ value: ScanResult?) throws -> ScanResult {
        guard let value else { throw MonitoringFailure(description: "Subtree replacement returned nil") }
        return value
    }
}

#if STORAGE_FIXTURE_RUNNER
#else
final class MonitoringTests: XCTestCase {
    func testIncrementalMerge() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonitoringTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try await MonitoringChecks.incrementalMerge(root)
    }

    func testFileSystemEvents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonitoringEvents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try await MonitoringChecks.fileSystemEvents(root)
    }
}
#endif
