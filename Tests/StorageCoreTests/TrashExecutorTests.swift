import Darwin
import Foundation
#if !STORAGE_FIXTURE_RUNNER
@testable import StorageCore
import XCTest
#endif

enum TrashChecks {
    struct Failure: Error { let reason: String }
    static func reject<T>(_ body: () throws -> T) throws {
        do { _ = try body() } catch { return }
        throw Failure(reason: "Expected rejection")
    }

    static func run() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: base) }
        guard let physical = realpath(base.path, nil) else { throw Failure(reason: "Fixture path") }
        defer { free(physical) }
        let home = URL(fileURLWithPath: String(cString: physical))
        let downloads = home.appendingPathComponent("Downloads")
        let trash = home.appendingPathComponent(".Trash")
        for folder in [downloads, trash] { try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }

        let file = downloads.appendingPathComponent("example.zip")
        try Data([1, 2]).write(to: file)
        let ticket = try TrashExecutor.prepare(file, home: home)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try reject { try TrashExecutor.execute(ticket, home: home, trash: trash) }
        try handle.close()
        try Data([9]).write(to: file)
        try reject { try TrashExecutor.execute(ticket, home: home, trash: trash) }
        let approved = try TrashExecutor.prepare(file, home: home)
        _ = try TrashExecutor.execute(approved, home: home, trash: trash)
        guard !fm.fileExists(atPath: file.path), try Data(contentsOf: trash.appendingPathComponent("example.zip")) == Data([9]) else {
            throw Failure(reason: "File did not move into fixture Trash")
        }
        try reject { try TrashExecutor.execute(approved, home: home, trash: trash) }
        for path in ["Downloads/live.sqlite", "Downloads/model.gguf", "Library/Application Support/data.log", "Documents/personal.pdf"] {
            let blocked = home.appendingPathComponent(path)
            try fm.createDirectory(at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([3]).write(to: blocked)
            try reject { try TrashExecutor.prepare(blocked, home: home) }
        }
        let original = trash.appendingPathComponent("example.zip")
        try Data([7]).write(to: file)
        let duplicateName = try TrashExecutor.prepare(file, home: home)
        _ = try TrashExecutor.execute(duplicateName, home: home, trash: trash)
        guard try Data(contentsOf: original) == Data([9]), try fm.contentsOfDirectory(atPath: trash.path).count == 2 else {
            throw Failure(reason: "Trash name collision lost a previously trashed file")
        }
        try fm.createSymbolicLink(at: home.appendingPathComponent("Desktop"), withDestinationURL: trash)
        try reject { try TrashExecutor.prepare(home.appendingPathComponent("Desktop/example.zip"), home: home) }
        try fm.createSymbolicLink(at: file, withDestinationURL: original)
        try reject { try TrashExecutor.prepare(file, home: home) }
    }
}
#if !STORAGE_FIXTURE_RUNNER
final class TrashExecutorTests: XCTestCase {
    func testValidationAndConfirmedMove() throws { try TrashChecks.run() }
}
#endif
