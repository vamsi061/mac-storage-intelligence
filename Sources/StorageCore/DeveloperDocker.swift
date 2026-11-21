import Darwin
import Foundation

struct DeveloperStorageError: LocalizedError {
    let errorDescription: String?
    init(_ reason: String) { errorDescription = reason }
}

public struct DockerResource: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case container, image, volume }
    public let kind: Kind
    public let identifier: String
    public let name: String
    public let detail: String
    public let bytes: Int64?
    public let canRemove: Bool
    public var id: String { kind.rawValue + "/" + identifier }

    public var consequence: String {
        kind == .container
            ? "Permanently remove this stopped container and its writable layer. Mounted volumes are retained."
            : "Permanently remove this local image without pruning parent images. Shared layers can remain in use."
    }
}

public struct DockerEndpoint: Identifiable, Hashable, Sendable {
    public let name: String
    public let socket: URL
    fileprivate let device: dev_t
    fileprivate let inode: ino_t
    public var id: String { socket.path }

    public static func discover() -> [Self] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [("Docker Desktop", home.appendingPathComponent(".docker/run/docker.sock"))]
        let profiles = home.appendingPathComponent(".colima")
        for url in (try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? [] {
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            paths.append(("Colima · " + url.lastPathComponent, url.appendingPathComponent("docker.sock")))
        }
        return paths.compactMap { name, socket in
            guard let info = socketInfo(socket) else { return nil }
            return Self(name: name, socket: socket, device: info.st_dev, inode: info.st_ino)
        }.sorted { $0.name < $1.name }
    }

    private static func socketInfo(_ socket: URL) -> stat? {
        var info = stat()
        guard socket.resolvingSymlinksInPath().path == socket.path, lstat(socket.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { return nil }
        return info
    }

    fileprivate func request(_ method: String, _ route: String) throws -> Data {
        guard let now = Self.socketInfo(socket), now.st_dev == device, now.st_ino == inode else {
            throw DeveloperStorageError("The local Docker engine socket changed. Refresh the inventory.")
        }
        // The system curl talks only to the pinned local Unix socket. Ignore curlrc and proxy settings.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["--disable", "--silent", "--show-error", "--fail", "--max-time", "8",
                          "--max-filesize", "8388608", "--noproxy", "*", "--unix-socket", socket.path,
                          "--request", method, "http://localhost" + route]
        task.environment = [:]
        task.currentDirectoryURL = URL(fileURLWithPath: "/")
        task.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        var output = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if output.count + chunk.count > 8 * 1024 * 1024 {
                task.terminate()
                pipe.fileHandleForReading.closeFile()
                task.waitUntilExit()
                throw DeveloperStorageError("Docker’s response exceeds the inventory limit.")
            }
            output.append(chunk)
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw DeveloperStorageError("Docker could not complete this request. " + String(decoding: output.prefix(300), as: UTF8.self))
        }
        return output
    }
}

public struct DockerInventory {
    private let request: (String, String) throws -> Data
    public init(endpoint: DockerEndpoint) { request = endpoint.request }
    init(request: @escaping (String, String) throws -> Data) { self.request = request }

    public func resources() throws -> [DockerResource] {
        struct Container: Decodable { var Id: String; var Names: [String]; var State: String; var Image: String }
        struct Image: Decodable { var Id: String; var RepoTags: [String]?; var Size: Int64 }
        struct Volumes: Decodable {
            struct Volume: Decodable { var Name: String; var Driver: String }
            var Volumes: [Volume]?
        }
        func validID(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        let decoder = JSONDecoder()
        let containers = try decoder.decode([Container].self, from: request("GET", "/containers/json?all=1"))
        let images = try decoder.decode([Image].self, from: request("GET", "/images/json"))
        let volumes = try decoder.decode(Volumes.self, from: request("GET", "/volumes"))
        var rows = containers.map {
            DockerResource(kind: .container, identifier: $0.Id, name: $0.Names.first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? $0.Id,
                          detail: $0.State + " · " + $0.Image, bytes: nil, canRemove: $0.State == "exited" && validID($0.Id))
        }
        rows += images.map {
            let tags = ($0.RepoTags ?? []).filter { $0 != "<none>:<none>" }
            return DockerResource(kind: .image, identifier: $0.Id, name: tags.isEmpty ? "Untagged image" : tags.joined(separator: ", "),
                                 detail: $0.Id, bytes: $0.Size, canRemove: tags.isEmpty && $0.Id.hasPrefix("sha256:") && validID(String($0.Id.dropFirst(7))))
        }
        rows += (volumes.Volumes ?? []).map {
            DockerResource(kind: .volume, identifier: $0.Name, name: $0.Name, detail: $0.Driver + " · persistent data", bytes: nil, canRemove: false)
        }
        return rows.sorted { ($0.kind.rawValue, $0.name, $0.id) < ($1.kind.rawValue, $1.name, $1.id) }
    }

    public func remove(_ resource: DockerResource) throws -> String {
        guard resource.canRemove, try resources().contains(resource) else {
            throw DeveloperStorageError("The resource changed or requires protection. Refresh and review it again.")
        }
        let route: String
        switch resource.kind {
        case .container: route = "/containers/" + resource.identifier + "?force=0&v=0"
        case .image: route = "/images/" + resource.identifier + "?force=0&noprune=1"
        case .volume: throw DeveloperStorageError("Volumes can contain irreplaceable data.")
        }
        _ = try request("DELETE", route)
        guard try !resources().contains(where: { $0.id == resource.id }) else {
            throw DeveloperStorageError("The Docker engine still lists this resource.")
        }
        return "Verified that the engine no longer lists " + resource.id + ". Shared layers and virtual disk allocation can limit space recovery."
    }
}
