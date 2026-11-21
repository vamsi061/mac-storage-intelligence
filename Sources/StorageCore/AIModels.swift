import CryptoKit
import Foundation

struct AIModelError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

public struct OllamaModel: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let digest: String
    public let bytes: Int64
    public let running: Bool?
    public let sharedBytes: Int64?
    public let exclusiveBytes: Int64?
    fileprivate let measuredStore: URL?
}

private final class LocalOllamaConnection: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        return URLSession(configuration: config, delegate: LocalOllamaConnection(), delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

func modelFreeSpace(_ url: URL?) -> Int64? {
    guard let url else { return nil }
    return try? VolumeService().volume(containing: url).availableBytes
}

func modelSpaceReport(before: Int64?, after: Int64?) -> String {
    guard let before, let after else { return "The model volume’s free-space change is unknown." }
    return "Observed volume free-space change: \(after - before) bytes (before \(before), after \(after)). Other disk activity can affect this measurement."
}

public struct OllamaService: Sendable {
    typealias LayerMap = [String: [String: Int64]]
    typealias Request = @Sendable (URLRequest) async throws -> (Data, Int)
    private let request: Request
    private let manifests: @Sendable () -> LayerMap
    private let store: URL?

    public init() {
        let path = ProcessInfo.processInfo.environment["OLLAMA_MODELS"]
        let store = path.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models")
        self.store = store
        manifests = { Self.readManifests(store.appendingPathComponent("manifests")) }
        request = { request in
            let (data, response) = try await LocalOllamaConnection.session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    init(request: @escaping Request, manifests: @escaping @Sendable () -> LayerMap) {
        self.request = request
        self.manifests = manifests
        store = nil
    }

    private struct Tag: Decodable { let name: String; let digest: String; let size: Int64 }
    private struct Loaded: Decodable { let name: String; let digest: String }
    private struct Listing<Entry: Decodable>: Decodable { let models: [Entry] }
    private struct Descriptor: Decodable { let digest: String; let size: Int64 }
    private struct Manifest: Decodable { let config: Descriptor; let layers: [Descriptor] }

    private static func readManifests(_ root: URL) -> LayerMap {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let paths = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return [:] }
        var result = LayerMap()
        for case let url as URL in paths {
            guard let info = try? url.resourceValues(forKeys: keys), info.isRegularFile == true,
                  info.isSymbolicLink == false, let size = info.fileSize, size <= 4_194_304,
                  let data = try? Data(contentsOf: url), let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
            var layers = [String: Int64]()
            for layer in manifest.layers + [manifest.config] where layer.size >= 0 {
                layers[layer.digest] = layer.size
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            result[digest] = layers
        }
        return result
    }

    private func call(_ endpoint: String, payload: String? = nil) async throws -> Data {
        var query = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/" + endpoint)!)
        if let payload {
            query.httpMethod = "DELETE"
            query.setValue("application/json", forHTTPHeaderField: "Content-Type")
            query.httpBody = try JSONEncoder().encode(["model": payload])
        }
        let (data, status) = try await request(query)
        guard (200..<300).contains(status) else {
            throw AIModelError("Ollama returned HTTP \(status). " + String(decoding: data.prefix(512), as: UTF8.self))
        }
        return data
    }

    private func tags() async throws -> [Tag] {
        try JSONDecoder().decode(Listing<Tag>.self, from: await call("tags")).models
    }

    public func models() async throws -> [OllamaModel] {
        let tags = try await tags()
        let loaded = try? JSONDecoder().decode(Listing<Loaded>.self, from: await call("ps")).models
        let layers = manifests()
        func digestKey(_ digest: String) -> String {
            digest.hasPrefix("sha256:") ? String(digest.dropFirst(7)) : digest
        }
        let complete = tags.allSatisfy { layers[digestKey($0.digest)] != nil }
        var references = [String: Int]()
        for tag in tags {
            if let blobs = layers[digestKey(tag.digest)] {
                for id in blobs.keys { references[id, default: 0] += 1 }
            }
        }
        return tags.map { tag in
            let blobs = layers[digestKey(tag.digest)]
            let totals = complete ? blobs?.reduce(into: (exclusive: Int64(0), shared: Int64(0))) { total, blob in
                if references[blob.key] == 1 { total.exclusive += blob.value }
                else { total.shared += blob.value }
            } : nil
            return OllamaModel(name: tag.name, digest: tag.digest, bytes: tag.size,
                               running: loaded.map { $0.contains { $0.name == tag.name || $0.digest == tag.digest } },
                               sharedBytes: totals?.shared, exclusiveBytes: totals?.exclusive,
                               measuredStore: blobs == nil ? nil : store)
        }
    }

    public func delete(_ selected: OllamaModel, confirmation: String) async throws -> String {
        guard confirmation == selected.name else { throw AIModelError("Type the exact model identifier.") }
        let current = try await models()
        guard let model = current.first(where: { $0.name == selected.name }), model.digest == selected.digest else {
            throw AIModelError("The model changed or disappeared. Refresh and review it again.")
        }
        guard model.running == false else { throw AIModelError("The model is running or its running status is unavailable.") }
        let before = modelFreeSpace(model.measuredStore)
        var failure: String?
        do { _ = try await call("delete", payload: model.name) }
        catch { failure = error.localizedDescription }
        let remaining = try? await tags()
        let absent = remaining.map { !$0.contains { $0.name == model.name } }
        let verification = absent == true ? "Verified removal of \(model.name)." :
            (absent == false ? "Model still listed." : "Could not verify the updated inventory.")
        let report = verification + " " + modelSpaceReport(before: before, after: modelFreeSpace(model.measuredStore))
        if let failure { throw AIModelError(failure + " " + report) }
        guard absent == true else { throw AIModelError(report) }
        return report
    }
}
