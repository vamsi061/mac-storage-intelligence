import Foundation

#if !STORAGE_FIXTURE_RUNNER
@testable import StorageCore
import XCTest
#endif

private struct RefreshFailure: Error, CustomStringConvertible {
    let description: String
}

enum DirectoryRefreshChecks {
    static func refresh(_ root: URL) async throws {
        let manager = FileManager.default
        let scanner = StorageScanner()
        let sibling = root.appendingPathComponent("sibling", isDirectory: true)
        try manager.createDirectory(at: sibling, withIntermediateDirectories: true)
        let stable = sibling.appendingPathComponent("stable")
        try Data([1]).write(to: stable)
        let old = root.appendingPathComponent("old")
        try Data([2]).write(to: old)
        let options = ScanOptions(largestFileLimit: 2)
        let initial = try await scanner.scan(root: root, options: options)

        // A separate, pending change in a retained sibling makes a recursive root scan detectable.
        try Data(repeating: 1, count: 20).write(to: stable)
        try manager.removeItem(at: old)
        let inserted = root.appendingPathComponent("inserted", isDirectory: true)
        try manager.createDirectory(at: inserted, withIntermediateDirectories: false)
        let inside = inserted.appendingPathComponent("inside")
        try Data(repeating: 3, count: 3).write(to: inside)
        let alias = root.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: sibling)
        let patched = try await scanner.refreshDirectory(at: root, in: initial, options: options)
        guard patched.root.logicalBytes == 4, patched.root.fileCount == 2, patched.skippedLinks == 1,
              patched.largestFiles.map(\.url) == [inside, stable] else {
            throw RefreshFailure(description: "Root refresh lost the new subtree, read a retained sibling, or followed a link")
        }
        let current = try await scanner.refreshDirectory(at: sibling, in: patched, options: options)
        let verified = try await scanner.scan(root: root, options: options)
        guard current.root.logicalBytes == verified.root.logicalBytes,
              current.root.allocatedBytes == verified.root.allocatedBytes,
              current.root.fileCount == verified.root.fileCount,
              current.largestFiles.map(\.url) == verified.largestFiles.map(\.url) else {
            throw RefreshFailure(description: "Refreshing the sibling did not converge with verification")
        }

        // Replace an ancestor with a symlink pointing to another tree with a matching nested name.
        let child = inserted.appendingPathComponent("child", isDirectory: true)
        try manager.createDirectory(at: child, withIntermediateDirectories: false)
        let withChild = try await scanner.refreshDirectory(at: inserted, in: current, options: options)
        try manager.moveItem(at: inserted, to: sibling.appendingPathComponent("moved"))
        try manager.createSymbolicLink(at: inserted, withDestinationURL: sibling.appendingPathComponent("moved"))
        do {
            _ = try await scanner.refreshDirectory(at: child, in: withChild, options: options)
        } catch {
            return
        }
        throw RefreshFailure(description: "Directory refresh followed an intermediate symlink")
    }
}

#if !STORAGE_FIXTURE_RUNNER
final class DirectoryRefreshTests: XCTestCase {
    func testDirectoryRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try await DirectoryRefreshChecks.refresh(root)
    }
}
#endif
