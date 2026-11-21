import Foundation
#if !STORAGE_FIXTURE_RUNNER
import XCTest
@testable import StorageCore
#endif

enum AIModelChecks {
    static func run() async throws {
        try await testSharedLayersCountOncePerModelAndStayAfterDelete()
        try await testChangedRunningAndUnconfirmedModelsCannotBeDeleted()
        try await testFailedDeletionPropagates()
    }
    static func testSharedLayersCountOncePerModelAndStayAfterDelete() async throws {
        let api = MockOllama()
        let service = OllamaService(request: { try await api.call($0) }, manifests: {
            ["aa": ["first": 10, "common": 25], "bb": ["common": 25]]
        })
        let rows = try await service.models()
        let selected = rows.first { $0.name == "first:latest" }!
        precondition(selected.sharedBytes == 25)
        precondition(selected.exclusiveBytes == 10)
        let result = try await service.delete(selected, confirmation: selected.name)
        precondition(result.contains("Verified"))
        let remaining = try await service.models()
        precondition(remaining.map(\.name) == ["second:latest"])
    }

    static func testChangedRunningAndUnconfirmedModelsCannotBeDeleted() async throws {
        let api = MockOllama()
        let service = OllamaService(request: { try await api.call($0) }, manifests: { [:] })
        let rows = try await service.models()
        let selected = rows.first!
        precondition(selected.sharedBytes == nil)
        for mode in ["wrong confirmation", "running", "changed", "missing status"] {
            await api.set(mode)
            do {
                _ = try await service.delete(selected, confirmation: mode == "wrong confirmation" ? "first" : selected.name)
                preconditionFailure("Unexpected deletion")
            } catch {}
        }
        let deletes = await api.deletes
        precondition(deletes == 0)
    }

    static func testFailedDeletionPropagates() async throws {
        let api = MockOllama()
        let service = OllamaService(request: { try await api.call($0) }, manifests: { [:] })
        let rows = try await service.models()
        let selected = rows.first!
        await api.set("delete failure")
        do { _ = try await service.delete(selected, confirmation: selected.name); preconditionFailure() }
        catch { precondition(error.localizedDescription.contains("503")) }
    }
}

private actor MockOllama {
    var mode = ""
    var deletes = 0
    var deleted = false
    func set(_ mode: String) { self.mode = mode }
    func call(_ request: URLRequest) throws -> (Data, Int) {
        switch request.url?.path {
        case "/api/tags":
            var tags = [["name": "second:latest", "digest": "bb", "size": 25] as [String: Any]]
            if !deleted {
                tags.insert(["name": "first:latest", "digest": mode == "changed" ? "cc" : "aa", "size": 35], at: 0)
            }
            return (try JSONSerialization.data(withJSONObject: ["models": tags]), 200)
        case "/api/ps":
            if mode == "missing status" { return (Data(), 500) }
            let running = mode == "running" ? [["name": "first:latest", "digest": "aa"]] : []
            return (try JSONSerialization.data(withJSONObject: ["models": running]), 200)
        case "/api/delete":
            deletes += 1
            precondition(request.httpMethod == "DELETE")
            let body = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
            precondition(body == ["model": "first:latest"])
            if mode == "delete failure" { return (Data(), 503) }
            deleted = true
            return (Data(), 200)
        default: throw URLError(.badURL)
        }
    }
}

#if !STORAGE_FIXTURE_RUNNER
final class AIModelsTests: XCTestCase {
    func testModels() async throws { try await AIModelChecks.run() }
}
#endif
