import Foundation
#if !STORAGE_FIXTURE_RUNNER
@testable import StorageCore
import XCTest
#endif

enum DeveloperStorageChecks {
    struct Failure: Error { let reason: String }
    static func run() throws {
        let container = String(repeating: "a", count: 64)
        let image = "sha256:" + String(repeating: "b", count: 64)
        var state = "exited"
        var deleted = false
        var imageDeleted = false
        let service = DockerInventory { method, route in
            let value: Any
            switch (method, route) {
            case ("GET", "/containers/json?all=1"):
                value = deleted ? [] : [["Id": container, "Names": ["/demo"], "State": state, "Image": "example:local"]]
            case ("GET", "/images/json"):
                value = imageDeleted ? [] : [["Id": image, "RepoTags": [], "Size": 100]]
            case ("GET", "/volumes"): value = ["Volumes": [["Name": "db", "Driver": "local"]]]
            case ("DELETE", "/containers/" + container + "?force=0&v=0"): deleted = true; value = [:]
            case ("DELETE", "/images/" + image + "?force=0&noprune=1"): imageDeleted = true; value = [:]
            default: throw Failure(reason: route)
            }
            return try JSONSerialization.data(withJSONObject: value)
        }
        let rows = try service.resources()
        guard rows.count == 3, let stopped = rows.first(where: { $0.kind == .container }),
              let dangling = rows.first(where: { $0.kind == .image }),
              rows.first(where: { $0.kind == .volume })?.canRemove == false else {
            throw Failure(reason: "Missing resources or unsafe volume action")
        }
        state = "running"
        do { _ = try service.remove(stopped); throw Failure(reason: "Accepted a running container") }
        catch let failure as Failure { throw failure } catch {}
        guard !deleted else { throw Failure(reason: "Deleted a running container") }
        state = "exited"
        _ = try service.remove(stopped)
        _ = try service.remove(dangling)
        guard try service.resources().map(\.name) == ["db"] else { throw Failure(reason: "Wrong survivors") }
        try DeveloperPackageChecks.run()
    }
}
#if !STORAGE_FIXTURE_RUNNER
final class DeveloperStorageTests: XCTestCase {
    func testDeveloperOperations() throws { try DeveloperStorageChecks.run() }
}
#endif
