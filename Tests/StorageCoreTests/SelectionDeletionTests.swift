import Darwin
import Foundation
#if !STORAGE_FIXTURE_RUNNER
@testable import StorageCore
import XCTest
#endif

enum SelectionDeletionChecks {
    static func run() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("selection-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temp) }
        guard let resolved = realpath(temp.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(resolved) }
        let home = URL(fileURLWithPath: String(cString: resolved))
        let documents = home.appendingPathComponent("Documents")
        let trash = home.appendingPathComponent(".Trash")
        for dir in [documents, trash] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let engine = SelectionDeletion(home: home)
        let file = documents.appendingPathComponent("weights.gguf")
        try Data([1]).write(to: file)
        let stale = try engine.prepare(file)
        try Data([2,3]).write(to: file, options: .atomic)
        try TrashChecks.reject { try engine.execute(stale, mode: .permanent) }
        let fresh = try engine.prepare(file)
        guard fresh.logicalBytes == 2 else { throw TrashChecks.Failure(reason: "Incorrect preview") }
        _ = try engine.execute(fresh, mode: .trash)
        guard try Data(contentsOf: trash.appendingPathComponent("weights.gguf")) == Data([2,3]) else {
            throw TrashChecks.Failure(reason: "Trash did not contain the confirmed file")
        }

        let folder = documents.appendingPathComponent("Research")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let nested = folder.appendingPathComponent("notes.txt")
        try Data([7]).write(to: nested)
        let tree = try engine.prepare(folder)
        try Data([8,9]).write(to: nested)
        try TrashChecks.reject { try engine.execute(tree, mode: .permanent) }
        let active = try FileHandle(forReadingFrom: nested)
        try TrashChecks.reject { try engine.prepare(folder) }
        try active.close()
        try fm.createSymbolicLink(at: folder.appendingPathComponent("redirect"), withDestinationURL: trash)
        try TrashChecks.reject { try engine.prepare(folder) }
        try fm.removeItem(at: folder.appendingPathComponent("redirect"))
        _ = try engine.execute(try engine.prepare(folder), mode: .permanent)
        guard !fm.fileExists(atPath: folder.path) else { throw TrashChecks.Failure(reason: "Folder still exists") }
        try TrashChecks.reject { try engine.prepare(documents) }
        try TrashChecks.reject { try engine.prepare(home) }
        try TrashChecks.reject { try engine.prepare(trash) }
        let app = home.appendingPathComponent("Applications/Example.app")
        let contents = app.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data([4]).write(to: contents.appendingPathComponent("resource"))
        try fm.createSymbolicLink(at: contents.appendingPathComponent("alias"), withDestinationURL: trash)
        try TrashChecks.reject { try engine.prepare(contents.appendingPathComponent("resource")) }
        _ = try engine.execute(try engine.prepare(app), mode: .permanent)
        guard fm.fileExists(atPath: trash.appendingPathComponent("weights.gguf").path),
              !fm.fileExists(atPath: app.path) else { throw TrashChecks.Failure(reason: "Bundle link target affected") }
    }
}
#if !STORAGE_FIXTURE_RUNNER
final class SelectionDeletionTests: XCTestCase {
    func testExplicitFileDirectoryAndApplicationActions() throws { try SelectionDeletionChecks.run() }
}
#endif
