import Darwin
import Foundation

/// A metadata-only, single-volume scanner. Each scan owns its traversal state.
public struct StorageScanner: Sendable {
    public init() {}

    public func scan(
        root: URL,
        options: ScanOptions = ScanOptions(),
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> ScanResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try ScanSession(options: options, progress: progress).run(root: root)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    /// Re-enumerate an anchor's immediate entries. Retained children with the same filesystem
    /// identity keep their measurements. New, replaced and unretained branches are traversed.
    public func refreshDirectory(
        at anchor: URL, in result: ScanResult, options: ScanOptions = ScanOptions()
    ) async throws -> ScanResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            guard let previous = result.deepestDirectory(containing: anchor.path),
                  previous.url.path == anchor.path else {
                throw scanError(anchor, EINVAL, "Unretained refresh directory")
            }
            let session = ScanSession(options: options, progress: { _ in })
            let descriptor = try session.openAnchor(anchor, under: result.root)
            session.displayedDirectories += result.root.counts.retainedDirectories - previous.counts.retainedDirectories
            for child in previous.children {
                var info = stat()
                if fstatat(descriptor, child.url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0,
                   FileIdentity(info) == child.identity {
                    session.retained[child.url.path] = child
                    session.displayedDirectories += child.counts.retainedDirectories
                }
            }
            let prefix = anchor.path == "/" ? "/" : anchor.path + "/"
            // Linked inodes owned elsewhere must stay assigned to their original branch.
            session.baselineLinks = result.linkedFileOwners
            session.linkedFileOwners = result.linkedFileOwners.filter { _, owner in
                let path = owner.path
                guard path.hasPrefix(prefix) else { return true }
                let suffix = path.dropFirst(prefix.count)
                guard let slash = suffix.firstIndex(of: "/") else { return false }
                return session.retained[prefix + suffix[..<slash]] != nil
            }
            let measurement = try session.run(root: anchor, descriptor: descriptor)
            // If an owner disappears, another name may be in an untouched branch. A full
            // verification can then elect the surviving owner without publishing a double count.
            guard result.linkedFileOwners.keys.allSatisfy({ measurement.linkedFileOwners[$0] != nil }) else {
                throw scanError(anchor, ESTALE, "Hard-link ownership changed during refresh")
            }
            guard let merged = result.mergingRefresh(previous: previous, measurement: measurement,
                                                      reused: session.reused, options: options) else {
                throw byteCountOverflow()
            }
            return merged
        }
        return try await withTaskCancellationHandler {
            let merged = try await worker.value
            try Task.checkCancellation()
            return merged
        } onCancel: { worker.cancel() }
    }
}

struct FileIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }
}

struct LinkedFileOwner: Sendable {
    let path: String
    let bytes: Int64
    let blocks: Int64
}

/// File names are evidence for conservative protection. No file contents are opened.
private enum Protection {
    static let markers: Set<String> = ["package.json", "Package.swift", "pyvenv.cfg"]

}

private struct Totals {
    var logical: Int64 = 0
    var allocated: Int64 = 0
    var files = 0

    mutating func add(_ other: Totals) throws {
        let (nextLogical, logicalOverflow) = logical.addingReportingOverflow(other.logical)
        let (nextAllocated, allocatedOverflow) = allocated.addingReportingOverflow(other.allocated)
        guard !logicalOverflow, !allocatedOverflow else { throw byteCountOverflow() }
        logical = nextLogical
        allocated = nextAllocated
        files += other.files
    }
}

private func byteCountOverflow() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(EOVERFLOW), userInfo: [
        NSLocalizedDescriptionKey: "This scan exceeds the supported 64-bit byte count."
    ])
}

private func scanError(_ url: URL, _ code: Int32, _ action: String) -> NSError {
    let reason = String(cString: strerror(code))
    return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
        NSFilePathErrorKey: url.path,
        NSLocalizedDescriptionKey: "\(action) \(url.path) — \(reason) (\(code))."
    ])
}

/// Owns a single open directory stream. Unwinding the stack also closes it on errors/cancellation.
private final class DirectoryFrame {
    static let openFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK

    let url: URL
    let path: String
    let stream: UnsafeMutablePointer<DIR>
    let descriptor: Int32
    let identity: FileIdentity
    let displayed: Bool
    var totals = Totals()
    var children: [DirectoryNode] = []
    var protectedOutsideChildren = false
    var markers: Set<String> = []
    var counts = ScanCounts()

    init(url: URL, descriptor fd: Int32, displayed: Bool) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            throw scanError(url, code, "Could not inspect")
        }
        guard let directory = fdopendir(fd) else {
            let code = errno
            close(fd)
            throw scanError(url, code, "Could not enumerate")
        }
        self.url = url
        self.path = url.path
        self.stream = directory
        self.descriptor = dirfd(directory)
        self.identity = FileIdentity(info)
        self.displayed = displayed
        counts.retainedDirectories = displayed ? 1 : 0
        protectedOutsideChildren = StorageFileKind.inferred(from: url.lastPathComponent) != .other
    }

    deinit { closedir(stream) }

    func node() -> DirectoryNode {
        DirectoryNode(
            url: url, logicalBytes: totals.logical, allocatedBytes: totals.allocated,
            fileCount: totals.files,
            children: children.sorted {
                if $0.logicalBytes != $1.logicalBytes { return $0.logicalBytes > $1.logicalBytes }
                return $0.url.path < $1.url.path
            }, hasProtectedContent: protectedOutsideChildren || children.contains(where: \.hasProtectedContent),
            projectMarkers: markers,
            identity: identity, counts: counts, protectedOutsideChildren: protectedOutsideChildren
        )
    }

    func childPath(_ name: String) -> String {
        path == "/" ? "/" + name : path + "/" + name
    }
}

/// A min-heap keeps the lowest-ranked retained file at its root.
private struct LargestFiles {
    let limit: Int
    var heap: [ScannedFile] = []
    private(set) var lowestRankedPath = ""

    static func precedes(_ a: ScannedFile, _ b: ScannedFile) -> Bool {
        if a.logicalBytes != b.logicalBytes { return a.logicalBytes > b.logicalBytes }
        return a.url.path < b.url.path
    }

    mutating func consider(logicalBytes: Int64, path: @autoclosure () -> String, makeFile: () -> ScannedFile) {
        guard limit > 0 else { return }
        if heap.count < limit {
            heap.append(makeFile())
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard Self.precedes(heap[parent], heap[child]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
            lowestRankedPath = heap[0].url.path
            return
        }

        guard logicalBytes > heap[0].logicalBytes ||
                (logicalBytes == heap[0].logicalBytes && path() < lowestRankedPath) else { return }
        let file = makeFile()
        heap[0] = file
        var parent = 0
        while parent * 2 + 1 < heap.count {
            var child = parent * 2 + 1
            if child + 1 < heap.count && Self.precedes(heap[child], heap[child + 1]) { child += 1 }
            guard Self.precedes(heap[parent], heap[child]) else { break }
            heap.swapAt(child, parent)
            parent = child
        }
        lowestRankedPath = heap[0].url.path
    }
}

private final class ScanSession {
    private static let nameOffset = MemoryLayout<dirent>.offset(of: \.d_name)!
    let options: ScanOptions
    let excludedPaths: Set<String>
    let progress: @Sendable (ScanProgress) -> Void
    var lastProgressTime = DispatchTime.now().uptimeNanoseconds

    var directoryIdentities: Set<FileIdentity> = []
    var linkedFileOwners: [FileIdentity: LinkedFileOwner] = [:]
    var baselineLinks: [FileIdentity: LinkedFileOwner]?
    var retained: [String: DirectoryNode] = [:]
    var reused: Set<String> = []
    var stack: [DirectoryFrame] = []
    var largest: LargestFiles
    var issues: [ScanIssue] = []
    var issueCount = 0
    var displayedDirectories = 1
    var entriesVisited = 0
    var totals = Totals()

    init(options: ScanOptions, progress: @escaping @Sendable (ScanProgress) -> Void) {
        self.options = options
        self.progress = progress
        self.largest = LargestFiles(limit: options.largestFileLimit)
        self.excludedPaths = Set(options.excludedPaths.map(Self.trimDirectorySuffix))
    }

    // A trailing slash or "/." would make open() dereference the selected directory symlink.
    static func trimDirectorySuffix(_ raw: String) -> String {
        var path = raw
        while path.count > 1 {
            if path.hasSuffix("/") { path.removeLast() }
            else if path.hasSuffix("/.") { path.removeLast() }
            else { break }
        }
        return path
    }

    /// Anchor all nested opens in the original directory and enforce its device at each step.
    func openAnchor(_ anchor: URL, under root: DirectoryNode) throws -> Int32 {
        let prefix = root.url.path == "/" ? "/" : root.url.path + "/"
        guard anchor.path == root.url.path || anchor.path.hasPrefix(prefix) else {
            throw scanError(anchor, EINVAL, "Outside scan root")
        }
        var fd = open(root.url.path, DirectoryFrame.openFlags)
        guard fd >= 0 else { throw scanError(root.url, errno, "Could not open") }
        var info = stat()
        guard fstat(fd, &info) == 0, FileIdentity(info) == root.identity else {
            close(fd)
            throw scanError(root.url, ESTALE, "Scan root changed")
        }
        let device = info.st_dev
        for component in anchor.path.dropFirst(prefix.count).split(separator: "/") {
            guard component != "..", component != "." else {
                close(fd)
                throw scanError(anchor, EINVAL, "Invalid refresh path")
            }
            let child = openat(fd, String(component), DirectoryFrame.openFlags)
            let code = errno
            close(fd)
            guard child >= 0 else { throw scanError(anchor, code, "Could not open") }
            fd = child
            guard fstat(fd, &info) == 0, info.st_dev == device else {
                close(fd)
                throw scanError(anchor, EXDEV, "Refresh crossed a volume boundary")
            }
        }
        return fd
    }

    func run(root: URL, descriptor: Int32? = nil) throws -> ScanResult {
        let path = Self.trimDirectorySuffix(root.path)
        guard root.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0),
              root.host?.isEmpty != false || root.host == "localhost" else {
            throw scanError(root, EINVAL, "Invalid local folder")
        }
        let fd = descriptor ?? open(path, DirectoryFrame.openFlags)
        guard fd >= 0 else { throw scanError(root, errno, "Could not open") }
        let frame = try DirectoryFrame(url: URL(fileURLWithPath: path, isDirectory: true), descriptor: fd, displayed: true)
        directoryIdentities.insert(frame.identity)
        stack.append(frame)
        emitProgress(path)

        if excludedPaths.contains(where: { $0 == path || $0 == "/" || (!$0.isEmpty && path.hasPrefix($0 + "/")) }) {
            frame.protectedOutsideChildren = true
            frame.counts.exclusions += 1
        } else {
            while let current = stack.last {
                try Task.checkCancellation()
                errno = 0
                if let entry = readdir(current.stream) {
                    try visit(entry, in: current, device: frame.identity.device)
                } else {
                    let code = errno
                    if code == EINTR { continue }
                    if code != 0 {
                        let error = scanError(current.url, code, "Could not finish reading")
                        if current === frame { throw error }
                        recordIssue(current.url, error.localizedDescription, code: code)
                    }

                    stack.removeLast()
                    if let parent = stack.last {
                        if !current.displayed && current.protectedOutsideChildren { parent.protectedOutsideChildren = true }
                        parent.counts.add(current.counts)
                        try parent.totals.add(current.totals)
                        if current.displayed { parent.children.append(current.node()) }
                    }
                }
            }
        }
        try Task.checkCancellation()
        emitProgress(path)
        return ScanResult(
            root: frame.node(), largestFiles: largest.heap.sorted(by: LargestFiles.precedes),
            issues: issues, issueCount: frame.counts.issues, skippedLinks: frame.counts.links,
            skippedMounts: frame.counts.mounts, skippedDuplicates: frame.counts.duplicates,
            excludedCount: frame.counts.exclusions, omittedDirectories: frame.counts.omissions, completedAt: Date(),
            linkedFileOwners: linkedFileOwners
        )
    }

    func visit(_ entry: UnsafeMutablePointer<dirent>, in parent: DirectoryFrame, device: dev_t) throws {
        // d_name is a NUL-terminated file-system representation. Reject unrepresentable names
        // instead of opening another entry under a lossy replacement string.
        // readdir can pack variable-length records; avoid copying a whole dirent or d_name tuple.
        let nameBytes = UnsafeRawPointer(entry).advanced(by: Self.nameOffset)
        guard let name = String(validatingCString: nameBytes.assumingMemoryBound(to: CChar.self)) else {
            entriesVisited += 1
            recordIssue(parent.url, "A filename in this directory could not be represented as UTF-8.")
            return
        }
        guard name != ".", name != ".." else { return }
        entriesVisited += 1
        let now = DispatchTime.now().uptimeNanoseconds
        if entriesVisited == 128 || now - lastProgressTime >= 120_000_000 {
            emitProgress(parent.childPath(name))
            try Task.checkCancellation()
            lastProgressTime = now
        }

        if !excludedPaths.isEmpty, excludedPaths.contains(parent.childPath(name)) {
            parent.protectedOutsideChildren = true
            parent.counts.exclusions += 1
            return
        }

        var info = stat()
        guard fstatat(parent.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            let url = parent.url.appendingPathComponent(name, isDirectory: false)
            recordIssue(url, scanError(url, code, "Could not inspect").localizedDescription, code: code)
            return
        }
        guard info.st_dev == device else {
            parent.protectedOutsideChildren = true
            parent.counts.mounts += 1
            return
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            parent.counts.links += 1
        case S_IFDIR:
            if !retained.isEmpty, let child = retained[parent.childPath(name)], child.identity == FileIdentity(info) {
                reused.insert(child.url.path)
                parent.children.append(child)
                parent.counts.add(child.counts)
                try parent.totals.add(Totals(logical: child.logicalBytes, allocated: child.allocatedBytes,
                                             files: child.fileCount))
                return
            }
            enterDirectory(parent: parent, name: name, expected: FileIdentity(info))
        case S_IFREG:
            if !parent.protectedOutsideChildren && StorageFileKind.inferred(from: name) != .other {
                parent.protectedOutsideChildren = true
            }
            if Protection.markers.contains(name) { parent.markers.insert(name) }
            if let baselineLinks, info.st_nlink == 1, baselineLinks[FileIdentity(info)] != nil {
                throw scanError(parent.url, ESTALE, "Hard-link ownership changed during refresh")
            }
            if info.st_nlink > 1 {
                let identity = FileIdentity(info)
                if let baselineLinks, baselineLinks[identity] == nil {
                    throw scanError(parent.url, ESTALE, "New hard-link ownership requires verification")
                }
                if let owner = linkedFileOwners[identity] {
                    if baselineLinks != nil && (owner.bytes != info.st_size || owner.blocks != info.st_blocks) {
                        throw scanError(parent.url, ESTALE, "Changes to a shared file require verification")
                    }
                    parent.counts.duplicates += 1
                    return
                }
                linkedFileOwners[identity] = LinkedFileOwner(path: parent.childPath(name), bytes: info.st_size,
                                                            blocks: info.st_blocks)
            }
            let (allocated, overflow) = max(0, info.st_blocks).multipliedReportingOverflow(by: 512)
            guard !overflow else { throw byteCountOverflow() }
            let size = Totals(logical: max(0, info.st_size), allocated: allocated, files: 1)
            try totals.add(size)
            try parent.totals.add(size)
            largest.consider(logicalBytes: size.logical, path: parent.childPath(name)) {
                let time = info.st_mtimespec
                let seconds = TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
                return ScannedFile(
                    url: parent.url.appendingPathComponent(name, isDirectory: false),
                    logicalBytes: size.logical, allocatedBytes: allocated,
                    modifiedAt: Date(timeIntervalSince1970: seconds)
                )
            }
        default:
            break // Devices, sockets and FIFOs have no regular-file payload to account for.
        }
    }

    func enterDirectory(parent: DirectoryFrame, name: String, expected: FileIdentity) {
        guard !directoryIdentities.contains(expected) else {
            parent.counts.duplicates += 1
            return
        }
        let url = parent.url.appendingPathComponent(name, isDirectory: true)
        let fd = openat(parent.descriptor, name, DirectoryFrame.openFlags)
        guard fd >= 0 else {
            let code = errno
            recordIssue(url, scanError(url, code, "Could not open").localizedDescription, code: code)
            return
        }
        do {
            // The stack holds the ancestors; this child sits `stack.count` levels below the root.
            let displayed = stack.count <= options.minimumRetainedDepth
                || displayedDirectories < options.directoryLimit
            let child = try DirectoryFrame(url: url, descriptor: fd, displayed: displayed)
            guard child.identity == expected else {
                recordIssue(url, "Directory changed between inspection and opening.")
                return
            }
            directoryIdentities.insert(expected)
            if displayed {
                displayedDirectories += 1
            } else {
                parent.counts.omissions += 1
            }
            stack.append(child)
        } catch {
            recordIssue(url, error.localizedDescription, code: Int32(exactly: (error as NSError).code))
        }
    }

    func recordIssue(_ url: URL, _ message: String, code: Int32? = nil) {
        stack.last?.protectedOutsideChildren = true
        stack.last?.counts.issues += 1
        issueCount += 1
        if issues.count < options.issueLimit { issues.append(ScanIssue(url: url, message: message, posixCode: code)) }
    }

    func emitProgress(_ path: String) {
        progress(ScanProgress(entriesVisited: entriesVisited, logicalBytes: totals.logical, currentPath: path,
                              filesMeasured: totals.files, allocatedBytes: totals.allocated, issueCount: issueCount))
    }
}
