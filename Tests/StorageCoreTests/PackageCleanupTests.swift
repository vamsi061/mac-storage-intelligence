import Foundation
#if !STORAGE_FIXTURE_RUNNER
@testable import StorageCore
import XCTest
#endif

enum PackageChecks {
    static func run() throws {
        let manager = FileManager.default
        let home = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let cache = home.appendingPathComponent("Library/Caches/pip")
        let wheels = cache.appendingPathComponent("wheels/a/b")
        try manager.createDirectory(at: wheels, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: home) }
        let wheel = wheels.appendingPathComponent("example-1.0-py3-none-any.whl")
        let sibling = wheels.appendingPathComponent("origin.json")
        let outside = home.appendingPathComponent("sentinel.whl")
        for file in [wheel, sibling, outside] { try Data([1]).write(to: file) }
        let original = try PackageCleanup.prepare(target: cache, home: home)
        try Data([1,2]).write(to: wheel)
        do {
            _ = try PackageCleanup.execute(original)
            throw PackageTestFailure("A changed target was accepted")
        } catch is PackageTestFailure { throw PackageTestFailure("A changed target was accepted") }
        catch {}
        let link = wheels.appendingPathComponent("linked-1.whl")
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        do {
            _ = try PackageCleanup.prepare(target: cache, home: home)
            throw PackageTestFailure("A symlink was accepted")
        } catch is PackageTestFailure { throw PackageTestFailure("A symlink was accepted") }
        catch {}
        try manager.removeItem(at: link)
        if ProcessInfo.processInfo.environment["MSI_TEST_REAL_PIP"] == "1" {
            let ticket = try PackageCleanup.prepare(target: cache, home: home)
            let report = try PackageCleanup.execute(ticket)
            guard report.contains("1 of 1"), !manager.fileExists(atPath: wheel.path),
                  manager.fileExists(atPath: sibling.path), manager.fileExists(atPath: outside.path) else {
                throw PackageTestFailure("pip touched an unexpected entry")
            }
        }
    }
}
private struct PackageTestFailure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
#if !STORAGE_FIXTURE_RUNNER
final class PackageCleanupTests: XCTestCase {
    func testIsolatedCache() throws { try PackageChecks.run() }
}
#endif
