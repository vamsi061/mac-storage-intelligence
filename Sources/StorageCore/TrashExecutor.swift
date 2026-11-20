import Darwin
import Foundation

public struct TrashTicket: Sendable {
    public let url: URL
    public let logicalBytes: Int64
    fileprivate let identity: TrashIdentity
}

fileprivate struct TrashIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let generation: UInt32
    let changed: Int
    let nanoseconds: Int

    init(_ file: stat) {
        device = file.st_dev
        inode = file.st_ino
        generation = file.st_gen
        changed = file.st_ctimespec.tv_sec
        nanoseconds = file.st_ctimespec.tv_nsec
    }
}

private struct TrashFailure: LocalizedError {
    let errorDescription: String?
    init(_ reason: String) { errorDescription = reason }
}

/// Only individual, explicitly selected regular files on the user's home volume can be moved.
public enum TrashExecutor {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static func prepare(_ url: URL) throws -> TrashTicket { try prepare(url, home: home) }
    public static func execute(_ ticket: TrashTicket) throws -> String {
        try execute(ticket, home: home, trash: home.appendingPathComponent(".Trash"))
    }
    public static func isEligibleLocation(_ url: URL) -> Bool { eligible(url, home: home) }

    private static let ordinary: Set<String> = [
        "log", "tmp", "temp", "zip", "gz", "tar", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg",
        "pdf", "txt", "csv", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "jpg", "jpeg", "png", "gif", "heic", "webp", "mov", "mp4", "m4v", "mp3", "wav"
    ]

    private static func eligible(_ url: URL, home: URL) -> Bool {
        guard url.isFileURL, url.baseURL == nil, url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.utf8.contains(0), url.path.hasPrefix(home.path + "/") else { return false }
        let parts = url.path.dropFirst(home.path.count + 1).components(separatedBy: "/")
        guard parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }), let name = parts.last else { return false }
        let ext = url.pathExtension.lowercased()
        if parts.count == 2 && ["Desktop", "Downloads"].contains(parts[0]) { return ordinary.contains(ext) }
        return parts.count >= 3 && parts.prefix(2).elementsEqual(["Library", "Logs"]) && ext == "log"
            && parts.dropLast().allSatisfy { !$0.lowercased().hasSuffix(".app") }
            && StorageFileKind.inferred(from: name) == .other
    }

    /// Resolve every component with O_NOFOLLOW, then pin the containing directory during the move.
    private static func directory(_ url: URL) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd = open("/", flags)
        guard fd >= 0 else { throw failure("Open filesystem root") }
        for part in url.path.split(separator: "/") {
            guard part != ".", part != ".." else { close(fd); throw TrashFailure("Invalid folder path.") }
            let next = openat(fd, String(part), flags)
            let error = errno
            close(fd)
            guard next >= 0 else { throw failure("Open folder without following links", error) }
            fd = next
        }
        return fd
    }

    private static func failure(_ action: String, _ code: Int32 = errno) -> TrashFailure {
        TrashFailure("\(action): \(String(cString: strerror(code))).")
    }

    private static func inspect(_ parent: Int32, _ url: URL) throws -> stat {
        var file = stat()
        guard fstatat(parent, url.lastPathComponent, &file, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("Inspect file") }
        guard file.st_mode & S_IFMT == S_IFREG, file.st_uid == getuid(), file.st_nlink == 1 else {
            throw TrashFailure("Choose a regular file you own with a single link.")
        }
        // Ask the kernel for positive references to this exact vnode. An API error blocks the action.
        var pid: Int32 = 0
        let bytes = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, url.path, 0, &pid, Int32(MemoryLayout.size(ofValue: pid)))
        guard bytes >= 0 else { throw failure("Check open file references") }
        guard bytes == 0 else { throw TrashFailure("A visible process has this file open. Close it and try again.") }
        return file
    }

    internal static func prepare(_ url: URL, home: URL) throws -> TrashTicket {
        guard eligible(url, home: home) else { throw TrashFailure("This location or file type is protected.") }
        let parent = try directory(url.deletingLastPathComponent())
        defer { close(parent) }
        let file = try inspect(parent, url)
        return TrashTicket(url: url, logicalBytes: file.st_size, identity: TrashIdentity(file))
    }

    internal static func execute(_ ticket: TrashTicket, home: URL, trash: URL) throws -> String {
        let url = ticket.url
        guard eligible(url, home: home) else { throw TrashFailure("This location is protected.") }
        let parent = try directory(url.deletingLastPathComponent())
        defer { close(parent) }
        let destination = try directory(trash)
        defer { close(destination) }
        var dest = stat()
        guard fstat(destination, &dest) == 0, dest.st_uid == getuid(), dest.st_dev == ticket.identity.device,
              dest.st_mode & 0o022 == 0 else { throw TrashFailure("A private Trash on the same volume is required.") }
        let before = available(parent)
        let file = try inspect(parent, url)
        guard TrashIdentity(file) == ticket.identity else { throw TrashFailure("The file changed. Review it again.") }
        let name = url.lastPathComponent
        var trashName = name
        if renameatx_np(parent, name, destination, trashName, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST else { throw failure("Move to Trash") }
            trashName = UUID().uuidString + "-" + name
            guard renameatx_np(parent, name, destination, trashName, UInt32(RENAME_EXCL)) == 0 else { throw failure("Move to Trash") }
        }
        var moved = stat()
        guard fstatat(destination, trashName, &moved, AT_SYMLINK_NOFOLLOW) == 0,
              moved.st_dev == file.st_dev, moved.st_ino == file.st_ino, moved.st_gen == file.st_gen else {
            if renameatx_np(destination, trashName, parent, name, UInt32(RENAME_EXCL)) == 0 {
                throw TrashFailure("The item changed during the move and was returned to its original location.")
            }
            throw TrashFailure("The item changed during the move. Inspect Trash for \(trashName).")
        }
        let measurement: String
        if let before, let after = available(parent) {
            measurement = "Available space changed by \(after - before) bytes on the source volume."
        } else { measurement = "Available space could not be measured." }
        return "Moved \(name) to Trash as \(trashName). \(measurement) Trash retains the file’s storage until emptied."
    }

    private static func available(_ fd: Int32) -> Int64? {
        var volume = statfs()
        guard fstatfs(fd, &volume) == 0 else { return nil }
        let result = volume.f_bavail.multipliedReportingOverflow(by: UInt64(volume.f_bsize))
        return result.overflow ? nil : Int64(exactly: result.partialValue)
    }
}
