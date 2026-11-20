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
}

private struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }
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
    var protectedContent = false
    var markers: Set<String> = []

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
        protectedContent = StorageFileKind.inferred(from: url.lastPathComponent) != .other
    }

    deinit { closedir(stream) }

    func node() -> DirectoryNode {
        DirectoryNode(
            url: url, logicalBytes: totals.logical, allocatedBytes: totals.allocated,
            fileCount: totals.files,
            children: children.sorted {
                if $0.logicalBytes != $1.logicalBytes { return $0.logicalBytes > $1.logicalBytes }
                return $0.url.path < $1.url.path
            }, hasProtectedContent: protectedContent, projectMarkers: markers
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
    var linkedFiles: Set<FileIdentity> = []
    var stack: [DirectoryFrame] = []
    var largest: LargestFiles
    var issues: [ScanIssue] = []
    var issueCount = 0
    var skippedLinks = 0
    var skippedMounts = 0
    var skippedDuplicates = 0
    var excludedCount = 0
    var omittedDirectories = 0
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

    func run(root: URL) throws -> ScanResult {
        try Task.checkCancellation()
        let path = Self.trimDirectorySuffix(root.path)
        guard root.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0),
              root.host?.isEmpty != false || root.host == "localhost" else {
            throw scanError(root, EINVAL, "Invalid local folder")
        }
        let fd = open(path, DirectoryFrame.openFlags)
        guard fd >= 0 else { throw scanError(root, errno, "Could not open") }
        let frame = try DirectoryFrame(url: URL(fileURLWithPath: path, isDirectory: true), descriptor: fd, displayed: true)
        directoryIdentities.insert(frame.identity)
        stack.append(frame)
        emitProgress(path)

        if excludedPaths.contains(where: { $0 == path || $0 == "/" || (!$0.isEmpty && path.hasPrefix($0 + "/")) }) {
            frame.protectedContent = true
            excludedCount += 1
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
                        parent.protectedContent = parent.protectedContent || current.protectedContent
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
            issues: issues, issueCount: issueCount, skippedLinks: skippedLinks,
            skippedMounts: skippedMounts, skippedDuplicates: skippedDuplicates,
            excludedCount: excludedCount, omittedDirectories: omittedDirectories, completedAt: Date()
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
            parent.protectedContent = true
            excludedCount += 1
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
            parent.protectedContent = true
            skippedMounts += 1
            return
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            skippedLinks += 1
        case S_IFDIR:
            enterDirectory(parent: parent, name: name, expected: FileIdentity(info))
        case S_IFREG:
            if !parent.protectedContent { parent.protectedContent = StorageFileKind.inferred(from: name) != .other }
            if Protection.markers.contains(name) { parent.markers.insert(name) }
            if info.st_nlink > 1 && !linkedFiles.insert(FileIdentity(info)).inserted {
                skippedDuplicates += 1
                return
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
            skippedDuplicates += 1
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
            let displayed = displayedDirectories < options.directoryLimit
            let child = try DirectoryFrame(url: url, descriptor: fd, displayed: displayed)
            guard child.identity == expected else {
                recordIssue(url, "Directory changed between inspection and opening.")
                return
            }
            directoryIdentities.insert(expected)
            if displayed { displayedDirectories += 1 } else { omittedDirectories += 1 }
            stack.append(child)
        } catch {
            recordIssue(url, error.localizedDescription, code: Int32(exactly: (error as NSError).code))
        }
    }

    func recordIssue(_ url: URL, _ message: String, code: Int32? = nil) {
        stack.last?.protectedContent = true
        issueCount += 1
        if issues.count < options.issueLimit { issues.append(ScanIssue(url: url, message: message, posixCode: code)) }
    }

    func emitProgress(_ path: String) {
        progress(ScanProgress(entriesVisited: entriesVisited, logicalBytes: totals.logical, currentPath: path,
                              filesMeasured: totals.files, allocatedBytes: totals.allocated, issueCount: issueCount))
    }
}
