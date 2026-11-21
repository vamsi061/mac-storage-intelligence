import Foundation
#if !STORAGE_FIXTURE_RUNNER
@testable import StorageCore
import XCTest
#endif

enum StorageAnalysisChecks {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private static func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageAnalysis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func volume(total: Int64, available: Int64, used: Int64) -> StorageVolume {
        StorageVolume(id: URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true),
                      name: "Data", totalBytes: total, availableBytes: available, usedBytes: used,
                      isReadOnly: false, isRemovable: false, filesystem: "apfs",
                      automaticallyInventoried: true)
    }

    static func run() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Users/current", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let resolver = ScanRootResolver(home: home)

        try require(resolver.defaultRoot.standardizedFileURL == home.standardizedFileURL,
                    "Default scan root did not resolve to the dynamic home")
        try require(resolver.validateStoredRoot(home.path).url == home.standardizedFileURL,
                    "A valid home folder was rejected")
        try require(resolver.validateStoredRoot(home.appendingPathComponent("Documents").path).url != nil,
                    "A readable folder under home was rejected")

        // Regression: an older build persisted this empty, root-owned firmlink target.
        let stale = resolver.validateStoredRoot("/System/Volumes/Data/home")
        try require(stale.url == nil && stale.rejection?.contains("system") == true,
                    "The /System/Volumes/Data/home default was not rejected")
        for invalid in ["", "relative/folder", "/", "/System/Volumes/Data", "/private/tmp",
                        root.appendingPathComponent("missing").path] {
            let result = resolver.validateStoredRoot(invalid)
            try require(result.url == nil, "Invalid stored root was accepted: \(invalid)")
        }
        let file = root.appendingPathComponent("regular")
        try Data([1]).write(to: file)
        try require(resolver.validateStoredRoot(file.path).url == nil,
                    "A regular file was accepted as a resume folder")

        // Measured breakdown: nested roots count once, shared storage is never added to used.
        let primary = StorageBreakdown.MeasuredRoot(url: URL(fileURLWithPath: "/Users/current"), allocatedBytes: 300)
        let app = StorageBreakdown.MeasuredRoot(url: URL(fileURLWithPath: "/Applications"), allocatedBytes: 100)
        let parent = StorageBreakdown.MeasuredRoot(url: URL(fileURLWithPath: "/Users"), allocatedBytes: 800)
        let sameHome = StorageBreakdown.MeasuredRoot(url: URL(fileURLWithPath: "/Users/current"), allocatedBytes: 300)
        let breakdown = StorageBreakdown(volume: volume(total: 1_000, available: 200, used: 600),
                                         primaryRoot: primary, additionalRoots: [app, parent, sameHome],
                                         recoverableBytes: 2_000, recoverableItems: 4)
        try require(breakdown.sharedBytes == 200, "Shared/reserved bytes were computed incorrectly")
        try require(breakdown.measuredRootCount == 2, "Overlapping measured roots were counted twice")
        try require(breakdown.measuredUserBytes == 300, "Primary user measurement is incorrect")
        try require(breakdown.measuredAccessibleBytes == 400, "Additional non-overlapping measurement is incorrect")
        try require(breakdown.unmeasuredBytes == 200, "Unmeasured occupied space is incorrect")
        try require(breakdown.recoverableBytes == 600 && breakdown.recoverableItems == 4,
                    "Recoverable storage was not bounded by occupied storage")

        // Every direct child from the Explorer on-demand measurement must carry its own measured
        // node, so the UI never renders a readable folder as permanently unmeasured.
        let scanRoot = root.appendingPathComponent("folders", isDirectory: true)
        for (folder, bytes) in [("alpha", 11), ("beta", 23), ("gamma", 37)] {
            let url = scanRoot.appendingPathComponent(folder).appendingPathComponent("nested/item")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url)
        }
        let limited = try awaitValue {
            try await StorageScanner().scan(root: scanRoot,
                                            options: ScanOptions(largestFileLimit: 0, directoryLimit: 1))
        }
        try require(limited.root.children.isEmpty && limited.root.logicalBytes == 71,
                    "Fixture did not exercise an omitted folder branch")
        let measured = try awaitValue {
            try await StorageScanner().scan(
                root: scanRoot,
                options: ScanOptions(largestFileLimit: 0, directoryLimit: 1, minimumRetainedDepth: 1))
        }
        try require(measured.root.children.count == 3, "On-demand child measurement lost folders")
        for child in measured.root.children {
            try require(child.logicalBytes > 0 && child.fileCount == 1,
                        "Explorer child folder remained unmeasured: \(child.url.lastPathComponent)")
        }

        // Cleanup ancestors at depth two must remain present in the retained tree even when the
        // directory budget is tiny; otherwise standard caches silently disappear from Cleanup.
        let cacheHome = root.appendingPathComponent("cache-home", isDirectory: true)
        let cachePaths = ["Library/Caches/pip/wheels/a.whl", ".npm/_cacache/content",
                          "Library/Caches/Google/Chrome/Cache/data"]
        for path in cachePaths {
            let url = cacheHome.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
        }
        let anchored = try awaitValue {
            try await StorageScanner().scan(
                root: cacheHome,
                options: ScanOptions(largestFileLimit: 0, directoryLimit: 1, minimumRetainedDepth: 4))
        }
        for path in ["Library/Caches/pip", ".npm/_cacache", "Library/Caches/Google/Chrome"] {
            let target = cacheHome.appendingPathComponent(path).path
            let node = anchored.deepestDirectory(containing: target)
            try require(node?.url.path == target && node?.fileCount == 1,
                        "Cleanup ancestor was omitted from the retained tree: \(path)")
        }
    }

    /// The fixture runner is synchronous; this helper drives a scanner that finishes immediately.
    private static func awaitValue<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var output: Result<T, Error>?
        Task.detached {
            do { output = .success(try await operation()) }
            catch { output = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        switch output {
        case .success(let value): return value
        case .failure(let error): throw error
        case nil: throw Failure("Scanner did not complete")
        }
    }
}

#if !STORAGE_FIXTURE_RUNNER
final class StorageAnalysisTests: XCTestCase {
    func testScanRootResolutionBreakdownAndExplorerMeasurements() throws {
        try StorageAnalysisChecks.run()
    }
}
#endif
