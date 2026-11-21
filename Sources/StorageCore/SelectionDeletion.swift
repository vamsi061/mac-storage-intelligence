import Darwin
import Foundation

public enum SelectionDeletionMode: String, Sendable, CaseIterable {
    case trash = "Move to Trash"
    case permanent = "Delete Permanently"
}

public struct SelectionDeletionTicket: Sendable {
    public let url: URL
    public let logicalBytes: Int64
    public let fileCount: Int
    public let isFolder: Bool
    fileprivate let entries: [String: EntryStamp]
    fileprivate let parent: SelectionIdentity
}

fileprivate struct SelectionIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let generation: UInt32
    init(_ s: stat) { device = s.st_dev; inode = s.st_ino; generation = s.st_gen }
}

fileprivate struct EntryStamp: Equatable, Sendable {
    let identity: SelectionIdentity
    let mode: mode_t
    let size: Int64
    let modified: timespec
    let changed: timespec
    init(_ s: stat) {
        identity = SelectionIdentity(s)
        mode = s.st_mode
        size = s.st_size
        modified = s.st_mtimespec
        changed = s.st_ctimespec
    }
    var isFolder: Bool { mode & S_IFMT == S_IFDIR }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.matchesAfterMove(rhs) && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
    }
    // rename changes ctime; identity, type, permissions, size and mtime still have to match.
    func matchesAfterMove(_ other: Self) -> Bool {
        identity == other.identity && mode == other.mode && size == other.size &&
        modified.tv_sec == other.modified.tv_sec && modified.tv_nsec == other.modified.tv_nsec
    }
}

public struct SelectionDeletion: Sendable {
    private let home: URL
    public init() { home = FileManager.default.homeDirectoryForCurrentUser }
    internal init(home: URL) { self.home = home }

    private let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    private let protectedRoots = ["desktop", "documents", "downloads", "music", "movies", "pictures", "public", "applications", "library"]
    private let managed = ["library", "system", "backups.backupdb", "mobile backups", "node_modules", "ollama", "huggingface"]
    private let protectedPackages = ["photoslibrary", "photolibrary", "musiclibrary", "sparsebundle", "backupbundle", "bundle", "framework"]

    /// Every component of the real path is opened without following links by the caller.
    private func root(for url: URL) throws -> URL {
        guard url.isFileURL, url.baseURL == nil, ["", "localhost"].contains(url.host ?? ""),
              !url.path.utf8.contains(0), url.path.hasPrefix("/") else { throw TrashFailure("Choose a local file or folder.") }
        let components = url.path.dropFirst().components(separatedBy: "/")
        guard components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { throw TrashFailure("Hidden or ambiguous paths are protected.") }
        let root: URL
        if url.path.hasPrefix(home.path + "/") {
            root = home
        } else if url.deletingLastPathComponent().path == "/Applications", url.pathExtension.lowercased() == "app" {
            root = URL(fileURLWithPath: "/Applications", isDirectory: true)
        } else if components.count > 2, components.first == "Volumes" {
            let mount = URL(fileURLWithPath: "/Volumes").appendingPathComponent(components[1])
            let values = try mount.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey, .volumeURLKey])
            guard values.volumeIsInternal == false, values.volumeIsLocal == true,
                  values.volume?.path == mount.path else { throw TrashFailure("Choose a local external volume.") }
            root = mount
        } else { throw TrashFailure("Choose an item in your home folder, an installed application you own, or a local external drive.") }
        let relative = url.path.dropFirst(root.path.count + 1).components(separatedBy: "/").map { $0.lowercased() }
        guard !(relative.count == 1 && protectedRoots.contains(relative[0])),
              !relative.contains(where: { managed.contains($0) }),
              !relative.dropLast().contains(where: { $0.hasSuffix(".app") || protectedName($0) }) else {
            throw TrashFailure("This system, application, or managed data location is protected.")
        }
        return root
    }

    private func protectedName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        let kind = StorageFileKind.inferred(from: name)
        return protectedPackages.contains(ext) || kind == .database || kind == .virtualMachine ||
            name.hasPrefix(".") || managed.contains(name.lowercased())
    }

    private func info(_ fd: Int32) throws -> stat {
        var s = stat()
        guard fstat(fd, &s) == 0 else { throw TrashExecutor.failure("Inspect open folder") }
        return s
    }

    private func info(_ parent: Int32, _ name: String) throws -> stat {
        var s = stat()
        guard fstatat(parent, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw TrashExecutor.failure("Inspect " + name) }
        return s
    }

    private func names(_ fd: Int32) throws -> [String] {
        let copy = openat(fd, ".", directoryFlags)
        guard copy >= 0 else { throw TrashExecutor.failure("Read folder") }
        guard let stream = fdopendir(copy) else { let err = errno; close(copy); throw TrashExecutor.failure("Read folder", err) }
        defer { closedir(stream) }
        var result: [String] = []
        let offset = MemoryLayout<dirent>.offset(of: \.d_name)!
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw TrashExecutor.failure("Read complete folder") }
                break
            }
            let rawName = UnsafeRawPointer(entry).advanced(by: offset).assumingMemoryBound(to: CChar.self)
            guard let name = String(validatingUTF8: rawName) else { throw TrashFailure("A filename cannot be displayed safely.") }
            if name != "." && name != ".." { result.append(name) }
        }
        return result
    }

    private func snapshot(_ parent: Int32, _ url: URL, device: dev_t, name: String? = nil,
                          approvedURL: URL? = nil, cancelled: () -> Bool) throws -> SelectionDeletionTicket {
        let approved = approvedURL ?? url
        let app = approved.pathExtension.lowercased() == "app"
        var entries = [String: EntryStamp]()
        var bytes: Int64 = 0
        var files = 0
        func visit(_ fd: Int32, _ name: String, _ relative: String, _ physical: URL, _ depth: Int) throws {
            if cancelled() { throw CancellationError() }
            guard depth < 256 else { throw TrashFailure("Folder nesting exceeds the safe inspection limit.") }
            let s = try info(fd, name)
            let stamp = EntryStamp(s)
            let type = s.st_mode & S_IFMT
            guard s.st_dev == device, s.st_uid == getuid(),
                  (type == S_IFREG && s.st_nlink == 1) || type == S_IFDIR || (app && type == S_IFLNK && !relative.isEmpty),
                  app || (!protectedName(relative.isEmpty ? approved.lastPathComponent : name) && (relative.isEmpty || !name.lowercased().hasSuffix(".app"))) else {
                throw TrashFailure("Protected, linked, differently owned, or unsupported item at " + physical.path)
            }
            guard entries[relative] == nil else { throw TrashFailure("Two filenames cannot be distinguished safely.") }
            entries[relative] = stamp
            // A directory fd opened by this traversal would itself count as a reference.
            if type != S_IFLNK {
                var pid: Int32 = 0
                let references = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, physical.path, 0, &pid, Int32(MemoryLayout<Int32>.size))
                guard references == 0 else { throw TrashFailure("An item is open, or its use could not be checked: " + physical.path) }
            }
            if type == S_IFDIR {
                let child = openat(fd, name, directoryFlags)
                guard child >= 0 else { throw TrashExecutor.failure("Open " + physical.path) }
                defer { close(child) }
                guard EntryStamp(try info(child)) == stamp else { throw TrashFailure("Folder changed during review.") }
                for entry in try names(child) {
                    try visit(child, entry, relative.isEmpty ? entry : relative + "/" + entry,
                              physical.appendingPathComponent(entry), depth + 1)
                }
            } else {
                files += 1
                let (sum, overflow) = bytes.addingReportingOverflow(max(0, s.st_size))
                guard !overflow else { throw TrashFailure("Selection size exceeds the supported range.") }
                bytes = sum
            }
            guard EntryStamp(try info(fd, name)) == stamp else { throw TrashFailure("Item changed during inspection. Review it again.") }
        }
        try visit(parent, name ?? url.lastPathComponent, "", url, 0)
        return SelectionDeletionTicket(url: url, logicalBytes: bytes, fileCount: files,
                                      isFolder: entries[""]!.isFolder, entries: entries, parent: SelectionIdentity(try info(parent)))
    }

    public func prepare(_ url: URL, cancelled: () -> Bool = { false }) throws -> SelectionDeletionTicket {
        let allowed = try root(for: url)
        let rootFD = try TrashExecutor.directory(allowed)
        defer { close(rootFD) }
        let parent = try TrashExecutor.directory(url.deletingLastPathComponent())
        defer { close(parent) }
        let device = try info(rootFD).st_dev
        guard try info(parent).st_dev == device else { throw TrashFailure("Nested mount points are protected.") }
        return try snapshot(parent, url, device: device, cancelled: cancelled)
    }

    private func rename(_ source: Int32, _ name: String, _ dest: Int32, _ newName: String) throws {
        guard renameatx_np(source, name, dest, newName, UInt32(RENAME_EXCL)) == 0 else { throw TrashExecutor.failure("Move " + name) }
    }

    public func execute(_ ticket: SelectionDeletionTicket, mode: SelectionDeletionMode,
                        cancelled: () -> Bool = { false }) throws -> String {
        let url = ticket.url
        let allowed = try root(for: url)
        let parent = try TrashExecutor.directory(url.deletingLastPathComponent())
        defer { close(parent) }
        guard SelectionIdentity(try info(parent)) == ticket.parent else { throw TrashFailure("The containing folder changed. Review it again.") }
        let device = ticket.parent.device
        let fresh = try snapshot(parent, url, device: device, cancelled: cancelled)
        guard fresh.entries == ticket.entries else { throw TrashFailure("The selected item or its contents changed. Review it again.") }

        var trash: Int32 = -1
        defer { if trash >= 0 { close(trash) } }
        if mode == .trash {
            let trashURL = allowed.path.hasPrefix("/Volumes/") ? allowed.appendingPathComponent(".Trashes/\(getuid())") : home.appendingPathComponent(".Trash")
            trash = try TrashExecutor.directory(trashURL)
            let s = try info(trash)
            guard s.st_dev == device, s.st_uid == getuid(), s.st_mode & 0o077 == 0 else {
                throw TrashFailure("A private Trash on the same volume is required.")
            }
        }
        if cancelled() { throw CancellationError() }
        let before = TrashExecutor.available(parent)
        let stagingName = ".storage-review-" + UUID().uuidString
        guard mkdirat(parent, stagingName, 0o700) == 0 else { throw TrashExecutor.failure("Create private staging folder") }
        let stage = openat(parent, stagingName, directoryFlags)
        guard stage >= 0 else { throw TrashExecutor.failure("Open private staging folder") }
        defer { close(stage) }
        let stageStat = try info(stage)
        guard stageStat.st_uid == getuid(), stageStat.st_mode & 0o077 == 0, stageStat.st_dev == device else {
            throw TrashFailure("The private staging folder changed.")
        }
        defer {
            if let current = try? info(parent, stagingName), SelectionIdentity(current) == SelectionIdentity(stageStat) {
                _ = unlinkat(parent, stagingName, AT_REMOVEDIR) // Only succeeds when empty.
            }
        }
        let name = url.lastPathComponent
        let stageURL = url.deletingLastPathComponent().appendingPathComponent(stagingName)
        let payload = "item"
        try rename(parent, name, stage, payload)
        var removed = 0
        var effect = ""
        do {
            let expected = ticket.entries[""]!
            guard expected.matchesAfterMove(EntryStamp(try info(stage, payload))) else { throw TrashFailure("The selected item was replaced during the move.") }
            // Recheck the entire private tree after capture, before committing either operation.
            let staged = try snapshot(stage, stageURL.appendingPathComponent(payload), device: device, name: payload,
                                      approvedURL: url, cancelled: cancelled)
            guard staged.entries.count == ticket.entries.count, staged.entries.allSatisfy({ path, entry in
                guard let original = ticket.entries[path] else { return false }
                return path.isEmpty ? original.matchesAfterMove(entry) : original == entry
            }) else { throw TrashFailure("The selected contents changed during the move.") }
            if cancelled() { throw CancellationError() }
            if mode == .trash {
                var destName = name
                if renameatx_np(stage, payload, trash, destName, UInt32(RENAME_EXCL)) != 0 {
                    guard errno == EEXIST else { throw TrashExecutor.failure("Move to Trash") }
                    destName = UUID().uuidString + "-" + String(name.suffix(42))
                    try rename(stage, payload, trash, destName)
                }
                guard expected.identity == SelectionIdentity(try info(trash, destName)) else {
                    throw TrashFailure("Trash changed during verification. Inspect " + destName + " in Trash.")
                }
                effect = "Moved to Trash as " + destName + ". Trash retains the storage until emptied."
            } else {
                try erase(parent: stage, name: payload, relative: "", entries: staged.entries,
                          staging: stage, removed: &removed, cancelled: cancelled)
                effect = "Permanently removed \(removed) filesystem entries."
            }
        } catch {
            let reason = error is CancellationError ? "Cancelled." : error.localizedDescription
            let partial = removed == 0 ? "" : " Already permanently removed \(removed) entries."
            var remaining = stat()
            if fstatat(stage, payload, &remaining, AT_SYMLINK_NOFOLLOW) == 0 {
                if renameatx_np(stage, payload, parent, name, UInt32(RENAME_EXCL)) == 0 {
                    throw TrashFailure(reason + partial + " The remaining item was returned to " + url.path + ".")
                }
                throw TrashFailure(reason + partial + " Recover the remaining item from " + stageURL.appendingPathComponent(payload).path + ".")
            }
            throw TrashFailure(reason + partial)
        }
        var source = stat()
        if fstatat(parent, name, &source, AT_SYMLINK_NOFOLLOW) == 0 {
            effect += " Another item now occupies the original path."
        } else if errno != ENOENT { effect += " The original path could not be rechecked." }
        if let before, let after = TrashExecutor.available(parent) {
            return effect + " Observed source-volume available-space change: \(after - before) bytes."
        }
        return effect + " Source-volume available space could not be measured."
    }

    /// Each reviewed child is atomically captured under an exclusive random name before unlinking.
    /// Unexpected entries are never visited for deletion; rmdir fails if anything remains.
    private func erase(parent: Int32, name: String, relative: String, entries: [String: EntryStamp],
                       staging: Int32, removed: inout Int, cancelled: () -> Bool) throws {
        if cancelled() { throw CancellationError() }
        guard let stamp = entries[relative], stamp == EntryStamp(try info(parent, name)) else {
            throw TrashFailure("An entry changed before removal: " + name)
        }
        let captured = relative.isEmpty ? name : "entry-" + UUID().uuidString
        if !relative.isEmpty { try rename(parent, name, staging, captured) }
        do {
            guard stamp.matchesAfterMove(EntryStamp(try info(staging, captured))) else { throw TrashFailure("An entry changed during capture.") }
            if stamp.isFolder {
                let fd = openat(staging, captured, directoryFlags)
                guard fd >= 0 else { throw TrashExecutor.failure("Open captured folder") }
                defer { close(fd) }
                guard SelectionIdentity(try info(fd)) == stamp.identity else { throw TrashFailure("Captured folder changed.") }
                for child in try names(fd) {
                    try erase(parent: fd, name: child, relative: relative.isEmpty ? child : relative + "/" + child,
                              entries: entries, staging: staging, removed: &removed, cancelled: cancelled)
                }
            }
            guard SelectionIdentity(try info(staging, captured)) == stamp.identity else { throw TrashFailure("Captured item changed.") }
            guard unlinkat(staging, captured, stamp.isFolder ? AT_REMOVEDIR : 0) == 0 else { throw TrashExecutor.failure("Remove captured item") }
            removed += 1
        } catch {
            if !relative.isEmpty, renameatx_np(staging, captured, parent, name, UInt32(RENAME_EXCL)) != 0 {
                throw TrashFailure(error.localizedDescription + " Inspect the private staging folder for " + captured + ".")
            }
            throw error
        }
    }
}
