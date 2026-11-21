import Darwin
import Foundation

public enum InventoryPaths {
    /// A firmlink may expose the same directory under both the startup root and its Data mount.
    public static func alias(of url: URL, under mount: URL) -> String? {
        let path = url.path
        if path == mount.path || path.hasPrefix(mount.path == "/" ? "/" : mount.path + "/") { return path }
        let candidate = mount.appendingPathComponent(String(path.dropFirst())).path
        var original = stat(), other = stat()
        guard lstat(path, &original) == 0, lstat(candidate, &other) == 0,
              original.st_dev == other.st_dev, original.st_ino == other.st_ino else { return nil }
        return candidate
    }

    public static func exclusions(_ paths: [String], for mount: URL) -> [String] {
        Array(Set(paths + paths.compactMap { alias(of: URL(fileURLWithPath: $0), under: mount) }))
    }
}

public struct InventoryItem: Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let kind: String
    public let directory: Bool
    public let link: Bool
    public let hidden: Bool
    public let logical: Int64?
    public let allocated: Int64?
    public let modified: Date?
    public let identity: String

    public init(_ url: URL, measurement: DirectoryNode? = nil) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.url = url
        directory = info.st_mode & S_IFMT == S_IFDIR
        link = info.st_mode & S_IFMT == S_IFLNK
        hidden = url.lastPathComponent.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0
        kind = link ? "Symbolic link" : directory ? (url.pathExtension.lowercased() == "app" ? "Application" : "Folder") :
            (url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased())
        logical = directory ? measurement?.logicalBytes : info.st_size
        allocated = directory ? measurement?.allocatedBytes : info.st_blocks * 512
        modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
        identity = "\(info.st_dev)/\(info.st_ino)"
    }
}

public struct DirectoryListing: Sendable {
    public var items: [InventoryItem] = []
    public var unreadable = 0

    public static func read(_ root: URL, measurements: [URL: DirectoryNode] = [:]) throws -> Self {
        let parent = try InventoryItem(root)
        guard parent.directory && !parent.link else { throw POSIXError(.ENOTDIR) }
        var listing = Self()
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try Task.checkCancellation()
            do { listing.items.append(try InventoryItem(url, measurement: measurements[url])) }
            catch { listing.unreadable += 1 }
        }
        return listing
    }
}

public enum SnapshotInventory {
    public static func names(on volume: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["apfs", "listSnapshots", "-plist", volume.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let snapshots = object["Snapshots"] as? [[String: Any]] else { throw CocoaError(.fileReadUnknown) }
        return try snapshots.map {
            guard let name = $0["SnapshotName"] as? String ?? $0["Name"] as? String else { throw CocoaError(.fileReadCorruptFile) }
            return name
        }
    }
}
