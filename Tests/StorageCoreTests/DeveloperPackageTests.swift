import Foundation
#if !STORAGE_FIXTURE_RUNNER
@testable import StorageCore
#endif

enum DeveloperPackageChecks {
    static func run() throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: "/private/tmp/" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        for spec in DeveloperCacheTool.allCases {
            let cache = home.appendingPathComponent(spec.relativePath)
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            let entry = cache.appendingPathComponent("example.data")
            try Data([1, 2]).write(to: entry)
            let draft = try DeveloperCacheSnapshot.capture(cache, expected: cache)
            guard draft.files == 1, draft.bytes == 2, spec.invocation(cache: cache).contains(where: { !$0.isEmpty }) else {
                throw DeveloperStorageChecks.Failure(reason: "Missing inventory for " + spec.rawValue)
            }
            let link = cache.appendingPathComponent("outside")
            try fm.createSymbolicLink(at: link, withDestinationURL: home)
            do {
                _ = try DeveloperCacheSnapshot.capture(cache, expected: cache)
                throw DeveloperStorageChecks.Failure(reason: "Accepted a linked cache entry")
            } catch let failure as DeveloperStorageChecks.Failure { throw failure } catch {}
            try fm.removeItem(at: link)
            try Data([3, 4, 5]).write(to: entry)
            guard try DeveloperCacheSnapshot.capture(cache, expected: cache) != draft else {
                throw DeveloperStorageChecks.Failure(reason: "Accepted a changed cache")
            }
        }
    }
}
