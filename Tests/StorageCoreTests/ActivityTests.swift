import Foundation
#if !STORAGE_FIXTURE_RUNNER
import StorageCore
import XCTest
#endif

enum ActivityChecks {
    static func run() throws {
        let fm = FileManager.default
        let tree = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tree, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tree) }
        let database = tree.appendingPathComponent("fixture.sqlite")
        try Data().write(to: database)
        let handle = try FileHandle(forReadingFrom: database)
        defer { try? handle.close() }
        let sibling = tree.appendingPathExtension("other")
        let snapshot = try StorageActivitySnapshot.capture(candidates: [tree, sibling])
        guard snapshot.protectionReason(for: tree) != nil, snapshot.protectionReason(for: sibling) == nil else {
            throw NSError(domain: "ActivityChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected only the directory containing the open fixture to be protected."])
        }
    }
}
#if !STORAGE_FIXTURE_RUNNER
final class StorageActivityTests: XCTestCase {
    func testOpenDatabaseProtectsItsDirectory() throws { try ActivityChecks.run() }
}
#endif
