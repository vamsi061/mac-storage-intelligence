import Darwin
import Foundation

public struct StorageVolume: Identifiable, Sendable {
    /// Mount URL, including the actual Data mount when queried through a firmlink.
    public let id: URL
    public let name: String
    public let totalBytes: Int64?
    public let availableBytes: Int64?
    public let usedBytes: Int64?
    public let isReadOnly: Bool
    public let isRemovable: Bool
}

public struct VolumeService: Sendable {
    public init() {}

    /// Presents the volume that holds the user's files first, followed by visible mounts.
    public func mountedVolumes() throws -> [StorageVolume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsReadOnlyKey]
        guard let mounts = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) else {
            throw VolumeError.unavailableMounts
        }
        let homeVolume = try? volume(containing: FileManager.default.homeDirectoryForCurrentUser)
        var result = [homeVolume].compactMap { $0 }
        var seen = Set(result.map(\.id))
        for mount in mounts {
            // A removable volume can disappear between enumeration and measurement.
            // Preserve the mount in the picker with unknown capacities if it does.
            guard !seen.contains(mount) else { continue }
            let volume = (try? volume(containing: mount)) ?? describe(mount, statistics: nil)
            if seen.insert(volume.id).inserted { result.append(volume) }
        }
        return result
    }

    public func volume(containing url: URL) throws -> StorageVolume {
        guard url.isFileURL else { throw VolumeError.invalidURL }
        var statistics = statfs()
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw VolumeError.invalidURL }
            guard statfs(path, &statistics) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let mount = withUnsafeBytes(of: &statistics.f_mntonname) { bytes -> URL in
            let path = bytes.bindMemory(to: CChar.self)
            return URL(fileURLWithFileSystemRepresentation: path.baseAddress!, isDirectory: true, relativeTo: nil)
        }
        return describe(mount, statistics: statistics)
    }

    private func describe(_ mount: URL, statistics: statfs?) -> StorageVolume {
        let metadata = try? mount.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsReadOnlyKey])
        let total = statistics.flatMap { bytes(blocks: $0.f_blocks, size: $0.f_bsize) }
        let available = statistics.flatMap { bytes(blocks: $0.f_bavail, size: $0.f_bsize) }
        let used = statistics.flatMap { _ in volumeUsedBytes(at: mount) }
        return StorageVolume(
            id: mount,
            name: metadata?.volumeLocalizedName ?? (mount.path == "/" ? "/" : mount.lastPathComponent),
            totalBytes: total,
            availableBytes: available,
            usedBytes: used,
            isReadOnly: statistics.map { ($0.f_flags & UInt32(MNT_RDONLY)) != 0 } ?? metadata?.volumeIsReadOnly ?? false,
            isRemovable: metadata?.volumeIsRemovable ?? false
        )
    }

    /// A space-sharing filesystem can report container-wide free blocks in statfs.
    /// Ask the mount directly for its own allocation, including on the sealed System volume.
    private func volumeUsedBytes(at mount: URL) -> Int64? {
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        request.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_SPACEUSED)

        // getattrlist packs the reply as length, returned attribute mask, then off_t.
        let maskOffset = MemoryLayout<UInt32>.size
        let valueOffset = maskOffset + MemoryLayout<attribute_set_t>.size
        let length = valueOffset + MemoryLayout<off_t>.size
        var reply = [UInt8](repeating: 0, count: length)
        return reply.withUnsafeMutableBytes { buffer in
            let status = mount.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return getattrlist(path, &request, buffer.baseAddress!, buffer.count, 0)
            }
            guard status == 0, buffer.loadUnaligned(as: UInt32.self) == UInt32(length) else { return nil }
            let mask = buffer.loadUnaligned(fromByteOffset: maskOffset, as: attribute_set_t.self)
            guard mask.volattr & UInt32(ATTR_VOL_SPACEUSED) != 0 else { return nil }
            let used = buffer.loadUnaligned(fromByteOffset: valueOffset, as: off_t.self)
            return used >= 0 ? used : nil
        }
    }

    private func bytes(blocks: UInt64, size: UInt32) -> Int64? {
        guard size > 0 else { return nil }
        let (bytes, overflow) = blocks.multipliedReportingOverflow(by: UInt64(size))
        return overflow ? nil : Int64(exactly: bytes)
    }
}

private enum VolumeError: LocalizedError {
    case unavailableMounts, invalidURL

    var errorDescription: String? {
        switch self {
        case .unavailableMounts: return "macOS could not list mounted volumes."
        case .invalidURL: return "Choose a folder on a mounted volume."
        }
    }
}
