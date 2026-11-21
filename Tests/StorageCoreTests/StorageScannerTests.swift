import Darwin
import Foundation

#if !STORAGE_FIXTURE_RUNNER
import StorageCore
import XCTest
#endif

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private struct SkippedCheck: Error {
    let reason: String
}

private func require(
    _ condition: @autoclosure () -> Bool, _ message: String,
    file: StaticString = #fileID, line: UInt = #line
) throws {
    if !condition() {
        throw CheckFailure(description: "\(file):\(line): \(message)")
    }
}

private typealias FixtureCheck = (URL) async throws -> Void

private func withFixture(_ check: FixtureCheck) async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("StorageScannerTests-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: false)
    do {
        try await check(root)
    } catch {
        try manager.removeItem(at: root)
        throw error
    }
    try manager.removeItem(at: root)
}

@discardableResult
private func writeFile(_ root: URL, _ name: String, bytes: Int) throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return url
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ScanProgress] = []

    func record(_ event: ScanProgress) {
        lock.withLock { events.append(event) }
    }

    var snapshot: [ScanProgress] {
        lock.withLock { events }
    }
}

private enum ScannerChecks {
    static func traversal(_ root: URL) async throws {
        try writeFile(root, "top", bytes: 6)
        let hidden = try writeFile(root, "Library/Lab.bundle/Contents/.hidden", bytes: 7)
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: hidden.path)
        try writeFile(root, "Library/empty-file", bytes: 0)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        let log = ProgressLog()
        let result = try await StorageScanner().scan(root: root, progress: { log.record($0) })
        try require(result.root.logicalBytes == 13 && result.root.fileCount == 3, "Incorrect recursive totals")
        try require(result.issueCount == 0 && result.issues.isEmpty, "Readable directory reported an error")
        let library = result.root.children.first { $0.url.lastPathComponent == "Library" }
        try require(library?.logicalBytes == 7 && library?.fileCount == 2, "Incorrect nested totals")
        try require(library?.children.first?.children.first?.logicalBytes == 7, "Package contents were lost")
        let empty = result.root.children.first { $0.url.lastPathComponent == "Empty" }
        try require(empty?.fileCount == 0 && empty?.logicalBytes == 0, "Empty directory was lost")
        try require(result.largestFiles.map(\.logicalBytes) == [7, 6, 0], "Largest files lost hidden or empty files")
        try require(result.largestFiles.first?.modifiedAt == modifiedAt, "Largest file lost its modification date")
        let events = log.snapshot
        try require(events.first?.entriesVisited == 0, "Initial progress missing")
        try require(events.last?.entriesVisited == 7 && events.last?.logicalBytes == 13, "Final progress differs from scan")
        try require(events.last?.filesMeasured == 3 && events.last?.allocatedBytes == result.root.allocatedBytes
                    && events.last?.issueCount == 0, "Final progress disagrees with measured files, allocation or coverage")
        for (earlier, later) in zip(events, events.dropFirst()) {
            try require(earlier.entriesVisited <= later.entriesVisited && earlier.logicalBytes <= later.logicalBytes,
                        "Progress went backwards")
        }
    }

    static func links(_ root: URL) async throws {
        let file = try writeFile(root, "folder/original", bytes: 9000)
        let manager = FileManager.default
        try manager.linkItem(at: file, to: root.appendingPathComponent("hard-link"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("folder/cycle"), withDestinationURL: root)
        try manager.createSymbolicLink(at: root.appendingPathComponent("file-link"), withDestinationURL: file)
        try manager.createSymbolicLink(at: root.appendingPathComponent("dangling"), withDestinationURL: root.appendingPathComponent("missing"))
        let result = try await StorageScanner().scan(root: root)
        try require(result.root.logicalBytes == 9000 && result.root.fileCount == 1, "Aliases double-counted content")
        try require(result.largestFiles.count == 1, "Hard link occupied a second largest-file slot")
        try require(result.skippedLinks == 3 && result.skippedDuplicates == 1, "Skipped link counts are incomplete")
        try require(result.issueCount == 0, "An intentional link skip was reported as an error")
    }

    static func sparseFile(_ root: URL) async throws {
        let url = try writeFile(root, "sparse", bytes: 0)
        let length: Int64 = 64 * 1024 * 1024
        let file = try FileHandle(forWritingTo: url)
        try file.seek(toOffset: UInt64(length - 1))
        try file.write(contentsOf: Data([0x41]))
        try file.close()
        var info = stat()
        try require(lstat(url.path, &info) == 0, "Cannot inspect sparse fixture")
        let expectedAllocation = Int64(info.st_blocks) * 512
        guard expectedAllocation < length else {
            throw SkippedCheck(reason: "The fixture volume allocated the full sparse file")
        }
        let result = try await StorageScanner().scan(root: root)
        try require(result.root.logicalBytes == length && result.root.allocatedBytes == expectedAllocation,
                    "Sparse-file aggregate confused file length with disk allocation")
        try require(result.largestFiles.first?.allocatedBytes == expectedAllocation, "Incorrect file allocation")
    }

    static func retentionLimits(_ root: URL) async throws {
        for number in 1...12 {
            try writeFile(root, "branch-\(number)/nested/item", bytes: number)
        }
        let scanner = StorageScanner()
        let result = try await scanner.scan(root: root, options: ScanOptions(largestFileLimit: 3, directoryLimit: 3))
        try require(result.root.fileCount == 12 && result.root.logicalBytes == 78, "Directory cap truncated aggregate totals")
        try require(result.largestFiles.map(\.logicalBytes) == [12, 11, 10], "Top three did not include all subtrees")
        try require(result.omittedDirectories == 22, "Incorrect omitted directory count")
        func countNodes(_ node: DirectoryNode) -> Int { 1 + node.children.reduce(0) { $0 + countNodes($1) } }
        try require(countNodes(result.root) == 3, "Retained directory count exceeded its budget")
        let minimal = try await scanner.scan(root: root, options: ScanOptions(largestFileLimit: 0, directoryLimit: 1))
        try require(minimal.largestFiles.isEmpty && minimal.root.children.isEmpty, "Zero file or child budget retained entries")
        try require(minimal.root.logicalBytes == 78, "Minimal presentation lost totals")
    }

    static func exclusions(_ root: URL) async throws {
        try writeFile(root, "Cache/subtree/value", bytes: 999)
        try writeFile(root, "CacheBackup/retain", bytes: 9)
        let excludedFile = try writeFile(root, "skip", bytes: 22)
        let options = ScanOptions(excludedPaths: [root.appendingPathComponent("Cache").path, excludedFile.path])
        let result = try await StorageScanner().scan(root: root, options: options)
        try require(result.root.fileCount == 1 && result.root.logicalBytes == 9, "Exclusion pruned the wrong entries")
        try require(result.excludedCount == 2 && result.largestFiles.first?.url.lastPathComponent == "retain",
                    "Subtree or exact-file exclusion failed")
        try require(result.root.hasProtectedContent, "An excluded subtree left its parent eligible for cleanup")
    }

    static func protectedContent(_ root: URL) async throws {
        let examples = ["invoice.PDF", "budget.numbers", "data.DB", "History-WAL", "catalog.sqlite-shm",
                        "cache.db-journal", "dev.vmdk", "image.dmg", "PG_VERSION"]
        for (index, name) in examples.enumerated() {
            try writeFile(root, "folder-\(index)/nested/\(name)", bytes: 1)
        }
        try writeFile(root, "machine.utm/Data/disk", bytes: 1)
        try writeFile(root, "ordinary/big.bin", bytes: 32)
        let scanner = StorageScanner()
        let result = try await scanner.scan(root: root, options: ScanOptions(largestFileLimit: 1))
        try require(result.largestFiles.first?.url.lastPathComponent == "big.bin", "Fixture did not truncate protected files")
        for folder in result.root.children {
            let expected = folder.url.lastPathComponent != "ordinary"
            try require(folder.hasProtectedContent == expected, "Incorrect safety flag for \(folder.url.lastPathComponent)")
        }
        let clipped = try await scanner.scan(root: root, options: ScanOptions(largestFileLimit: 0, directoryLimit: 1))
        try require(clipped.root.hasProtectedContent && clipped.root.children.isEmpty,
                    "Discarding directory rows or largest files erased a descendant's protection")
    }

    static func projectMarkers(_ root: URL) async throws {
        try writeFile(root, "web/package.json", bytes: 0)
        try writeFile(root, "web/.venv/pyvenv.cfg", bytes: 0)
        try writeFile(root, "swift/Package.swift", bytes: 0)
        let target = try writeFile(root, "other/source", bytes: 1)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("other/package.json"), withDestinationURL: target)
        let result = try await StorageScanner().scan(root: root, options: ScanOptions(largestFileLimit: 0))
        let web = result.root.children.first { $0.url.lastPathComponent == "web" }
        try require(web?.projectMarkers == ["package.json"] && web?.children.first?.projectMarkers == ["pyvenv.cfg"],
                    "Project markers must belong to their immediate directories")
        let swift = result.root.children.first { $0.url.lastPathComponent == "swift" }
        let other = result.root.children.first { $0.url.lastPathComponent == "other" }
        try require(swift?.projectMarkers == ["Package.swift"] && other?.projectMarkers.isEmpty == true
                    && result.root.projectMarkers.isEmpty, "Symlinked or nested markers contaminated project evidence")
    }

    static func invalidRoots(_ root: URL) async throws {
        let file = try writeFile(root, "regular", bytes: 2)
        let link = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let linkWithDot = URL(fileURLWithPath: link.path + "/.", isDirectory: true)
        for invalid in [file, link, linkWithDot, root.appendingPathComponent("missing")] {
            do {
                _ = try await StorageScanner().scan(root: invalid)
            } catch {
                continue
            }
            throw CheckFailure(description: "Accepted invalid scan root \(invalid.lastPathComponent)")
        }
    }

    static func permissionFailures(_ root: URL) async throws {
        let manager = FileManager.default
        let metadataOnly = try writeFile(root, "visible", bytes: 23)
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: metadataOnly.path)
        let privateFolders = ["private-a", "private-b"].map { root.appendingPathComponent($0) }
        defer {
            for url in privateFolders {
                _ = chmod(url.path, 0o700)
            }
        }
        for url in privateFolders {
            try writeFile(url, "hidden", bytes: 5)
            try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        }
        if let directory = opendir(privateFolders[0].path) {
            closedir(directory)
            throw SkippedCheck(reason: "This account can enumerate mode-000 fixture directories")
        }
        let log = ProgressLog()
        let result = try await StorageScanner().scan(root: root, options: ScanOptions(issueLimit: 1), progress: { log.record($0) })
        try require(result.root.fileCount == 1 && result.root.logicalBytes == 23, "Unreadable paths contaminated totals")
        try require(result.issueCount == 2 && result.issues.count == 1, "Issue cap truncated total failures or failed to cap details")
        let issue = result.issues[0]
        try require(issue.posixCode == EACCES || issue.posixCode == EPERM, "Diagnostic lost the OS permission error")
        try require(result.root.hasProtectedContent && log.snapshot.last?.issueCount == 2,
                    "Incomplete inspection was lost from protection or live coverage")
        try require(privateFolders.contains { $0.path == issue.url.path } && !issue.message.isEmpty,
                    "Issue omitted the failing path or explanation")
    }

    static func cancellation(_ root: URL) async throws {
        let fileCount = 512
        for i in 0..<fileCount { try Data([1]).write(to: root.appendingPathComponent("cancel-\(i)")) }
        for atStart in [true, false] {
            try await expectCancellation(root: root, fileCount: fileCount, atStart: atStart)
        }
    }

    private static func expectCancellation(root: URL, fileCount: Int, atStart: Bool) async throws {
        let (started, signal) = AsyncStream<Void>.makeStream()
        let resume = DispatchSemaphore(value: 0)
        let scan = Task.detached {
            try await StorageScanner().scan(root: root) { progress in
                let inTraversal = progress.filesMeasured > 0 && progress.entriesVisited < fileCount
                if atStart ? progress.entriesVisited == 0 : inTraversal {
                    signal.yield(())
                    _ = resume.wait(timeout: .now() + 5)
                }
            }
        }
        // Finishing the stream also wakes the test if an implementation drops progress entirely.
        let completion = Task {
            _ = await scan.result
            signal.finish()
        }
        var events = started.makeAsyncIterator()
        let received = await events.next() != nil
        scan.cancel()
        resume.signal()
        await completion.value
        try require(received, "Scan completed without reporting a cancellable \(atStart ? "start" : "intermediate update")")
        do {
            _ = try await scan.value
        } catch is CancellationError {
            return
        }
        throw CheckFailure(description: "Cancelled scan returned a completed result")
    }

    static func changingDirectory(_ root: URL) async throws {
        let stable = try writeFile(root, "stable", bytes: 64)
        let transient = root.appendingPathComponent("transient")
        try FileManager.default.createDirectory(at: transient, withIntermediateDirectories: true)
        for i in 0..<1024 {
            try Data([1]).write(to: transient.appendingPathComponent("\(i)"))
        }
        let (ready, start) = AsyncStream<Void>.makeStream()
        let removal = Task.detached {
            for await _ in ready {
                for i in 0..<1024 {
                    try FileManager.default.removeItem(at: transient.appendingPathComponent("\(i)"))
                }
                break
            }
        }
        let result: ScanResult
        do {
            result = try await StorageScanner().scan(root: root) { event in
                if event.entriesVisited == 0 { start.yield(()) }
            }
        } catch {
            start.finish()
            _ = await removal.result
            throw error
        }
        start.finish()
        try await removal.value
        try require(result.largestFiles.first?.url.path == stable.path, "Changes in a sibling hid the stable file")
        try require((1...1025).contains(result.root.fileCount), "Changed files were counted more than once")
        try require(result.root.logicalBytes == 64 + Int64(result.root.fileCount - 1), "Changed files left inconsistent totals")
        let rescan = try await StorageScanner().scan(root: root)
        try require(rescan.root.logicalBytes == 64 && rescan.root.fileCount == 1, "Rescan retained removed entries")
    }

    static func wideDirectory(_ root: URL) async throws {
        let fileCount = 10_000
        for i in 0..<fileCount {
            let url = root.appendingPathComponent("file-\(i)")
            try Data().write(to: url)
        }
        let options = ScanOptions(largestFileLimit: 12, directoryLimit: 5, issueLimit: 3)
        let log = ProgressLog()
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try await StorageScanner().scan(root: root, options: options, progress: { log.record($0) })
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let throughput = Double(fileCount) / elapsed
        print(String(format: "Benchmark: %d files in %.3f s (%.0f files/s, target >= 1,000 files/s)",
                     fileCount, elapsed, throughput))
        try require(result.root.fileCount == fileCount && result.root.logicalBytes == 0, "Wide directory lost entries")
        try require(result.largestFiles.count == 12 && result.issueCount == 0, "Wide scan produced an incorrect result")
        let retained = result.largestFiles.map { $0.url.lastPathComponent }
        let expected = [0, 1, 10, 100] + Array(1000...1007)
        try require(retained == expected.map { "file-\($0)" }, "Equal-size ranking depends on enumeration order")
        try require(log.snapshot.last?.entriesVisited == fileCount, "Final progress omitted entries in a wide directory")
        try require(throughput >= 1000, "Metadata scan of a local 10,000-file fixture exceeded 10 seconds")
    }
}

#if STORAGE_FIXTURE_RUNNER
@main
private enum FixtureRunner {
    private static func mountedBoundary(_ root: URL) async throws {
        let mounted = root.appendingPathComponent("mounted", isDirectory: true)
        let result = try await StorageScanner().scan(root: root)
        try require(result.skippedMounts == 1 && result.issueCount == 0, "Mounted child was not skipped cleanly")
        try require(result.root.fileCount == 1 && result.root.logicalBytes == 5, "Nested volume inflated the parent totals")
        try require(result.largestFiles.map { $0.url.lastPathComponent } == ["local-file"], "Image content escaped the mount boundary")
        let refreshed = try await StorageScanner().refreshDirectory(at: root, in: result)
        try require(refreshed.skippedMounts == 1 && refreshed.root.fileCount == 1 && refreshed.root.logicalBytes == 5,
                    "Incremental refresh crossed or lost the nested APFS mount boundary")
        let imageResult = try await StorageScanner().scan(root: mounted)
        try require(imageResult.largestFiles.contains { $0.url.lastPathComponent == "image-file" && $0.logicalBytes == 22 },
                    "Selecting the mounted volume directly did not discover its fixture file")
    }

    static func main() async {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--mounted-fixture" {
            do {
                try await mountedBoundary(URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
                print("PASS nested APFS mount and direct mounted-volume scan")
                return
            } catch {
                print("FAIL mount boundary: \(error)")
                exit(1)
            }
        }
        let cases: [(String, FixtureCheck)] = [
            ("directory traversal and progress", ScannerChecks.traversal),
            ("symbolic links and hard links", ScannerChecks.links),
            ("sparse file allocation", ScannerChecks.sparseFile),
            ("bounded directory and file lists", ScannerChecks.retentionLimits),
            ("directory and file exclusions", ScannerChecks.exclusions),
            ("protected content across retained and omitted directories", ScannerChecks.protectedContent),
            ("direct project markers independent of largest files", ScannerChecks.projectMarkers),
            ("invalid scan roots", ScannerChecks.invalidRoots),
            ("permission errors and issue limits", ScannerChecks.permissionFailures),
            ("caller cancellation", ScannerChecks.cancellation),
            ("files removed during traversal", ScannerChecks.changingDirectory),
            ("incremental subtree updates", MonitoringChecks.incrementalMerge),
            ("direct directory refresh", DirectoryRefreshChecks.refresh),
            ("retained depth for incremental anchors", MonitoringChecks.retainedDepth),
            ("file system event delivery", MonitoringChecks.fileSystemEvents),
            ("wide-directory benchmark", ScannerChecks.wideDirectory)
        ]
        var failed = 0
        var skipped = 0
        for (name, check) in cases {
            do {
                try await withFixture(check)
                print("PASS \(name)")
            } catch let skip as SkippedCheck {
                skipped += 1
                print("SKIP \(name): \(skip.reason)")
            } catch {
                failed += 1
                print("FAIL \(name): \(error)")
            }
        }
        let otherChecks: [(String, () throws -> Void)] = [
            ("volume checks", VolumeChecks.run),
            ("pip wheel cleanup", PackageChecks.run),
            ("confirmed Trash move and rejection cases", TrashChecks.run),
            ("treemap geometry", TreemapChecks.run),
            ("open file activity", ActivityChecks.run),
            ("cleanup recommendation checks", RecommendationChecks.run),
            ("recoverability policy checks", RecoverabilityChecks.run),
            ("scan scope, breakdown and folder measurement checks", StorageAnalysisChecks.run)
        ]
        for (name, check) in otherChecks {
            do {
                try check()
                print("PASS \(name)")
            } catch {
                failed += 1
                print("FAIL \(name): \(error)")
            }
        }
        print("\(cases.count + otherChecks.count - failed - skipped) checks passed, \(skipped) skipped, \(failed) failed")
        print("Optional APFS mount check: Scripts/test-scanner.sh --mount-boundary")
        if failed != 0 { exit(1) }
    }
}
#else
final class StorageScannerTests: XCTestCase {
    func testTraversalAndProgress() async throws { try await withFixture(ScannerChecks.traversal) }
    func testSymbolicLinksAndHardLinks() async throws { try await withFixture(ScannerChecks.links) }
    func testSparseFileAllocation() async throws { try await runOrSkip(ScannerChecks.sparseFile) }
    func testRetentionLimits() async throws { try await withFixture(ScannerChecks.retentionLimits) }
    func testExclusions() async throws { try await withFixture(ScannerChecks.exclusions) }
    func testProtectedContentAggregation() async throws { try await withFixture(ScannerChecks.protectedContent) }
    func testDirectProjectMarkers() async throws { try await withFixture(ScannerChecks.projectMarkers) }
    func testInvalidRoots() async throws { try await withFixture(ScannerChecks.invalidRoots) }
    func testPermissionFailures() async throws { try await runOrSkip(ScannerChecks.permissionFailures) }
    func testCancellation() async throws { try await withFixture(ScannerChecks.cancellation) }
    func testChangingDirectory() async throws { try await withFixture(ScannerChecks.changingDirectory) }
    func testWideDirectoryPerformance() async throws { try await withFixture(ScannerChecks.wideDirectory) }

    private func runOrSkip(_ check: FixtureCheck) async throws {
        do {
            try await withFixture(check)
        } catch let skip as SkippedCheck {
            throw XCTSkip(skip.reason)
        }
    }
}
#endif
