import CoreServices
import Darwin
import Foundation

/// A path and the flags observed for it in a coalesced FSEvents batch.
public struct FileSystemChange: Sendable {
    public let path: String
    public let flags: UInt32

    public init(path: String, flags: UInt32) {
        self.path = path
        self.flags = flags
    }

    public var isCreated: Bool { flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 }
    public var isRemoved: Bool { flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 }
    public var isModified: Bool { flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 }
    public var isRenamed: Bool { flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 }
    public var isRootChanged: Bool { flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 }

    /// The kernel can report a dropped or widened event stream, or the root can move.
    /// Any of these requires a full reconciliation scan rather than a subtree update.
    public var requiresFullRescan: Bool {
        let flags = self.flags
        let rescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
            | UInt32(kFSEventStreamEventFlagUserDropped)
            | UInt32(kFSEventStreamEventFlagKernelDropped)
            | UInt32(kFSEventStreamEventFlagEventIdsWrapped)
            | UInt32(kFSEventStreamEventFlagRootChanged)
        return flags & rescanFlags != 0
    }

    public var isDirectory: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 }
}

/// Watches one directory tree with FSEvents. Events are coalesced by the kernel over
/// `latency` seconds and delivered on a private serial queue.
public final class FileSystemEventMonitor: @unchecked Sendable {
    public enum MonitorError: LocalizedError {
        case creationFailed
        case startFailed

        public var errorDescription: String? {
            switch self {
            case .creationFailed: return "macOS could not create a file system event stream for this folder."
            case .startFailed: return "macOS refused to start file system monitoring for this folder."
            }
        }
    }

    public let root: URL
    private let latency: TimeInterval
    private let handler: @Sendable ([FileSystemChange]) -> Void
    private let queue = DispatchQueue(label: "storage.fsevents", qos: .utility)
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var running = false

    public init(root: URL, latency: TimeInterval = 0.6,
                handler: @escaping @Sendable ([FileSystemChange]) -> Void) {
        self.root = root
        self.latency = max(0.1, latency)
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        let box = CallbackBox(root: root, handler: handler)
        let info = Unmanaged.passRetained(box)
        var context = FSEventStreamContext(
            version: 0, info: info.toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<CallbackBox>.fromOpaque(pointer).release() }
            }, copyDescription: nil
        )
        defer { info.release() }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagWatchRoot)
            | UInt32(kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, eventStreamCallback, &context,
            [box.physicalRoot] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, flags
        ) else {
            throw MonitorError.creationFailed
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw MonitorError.startFailed
        }
        stream = created
        running = true
    }

    public func stop() {
        lock.lock()
        guard running, let stream else { lock.unlock(); return }
        self.stream = nil
        running = false
        lock.unlock()

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }
}

private final class CallbackBox {
    let handler: @Sendable ([FileSystemChange]) -> Void
    let physicalRoot: String
    let requestedRoot: String

    init(root: URL, handler: @escaping @Sendable ([FileSystemChange]) -> Void) {
        requestedRoot = root.path
        if let resolved = realpath(root.path, nil) {
            physicalRoot = FileManager.default.string(withFileSystemRepresentation: resolved, length: strlen(resolved))
            free(resolved)
        } else {
            physicalRoot = root.path
        }
        self.handler = handler
    }

    func reportedPath(_ path: String) -> String {
        guard physicalRoot != requestedRoot else { return path }
        if path == physicalRoot { return requestedRoot }
        let prefix = physicalRoot == "/" ? "/" : physicalRoot + "/"
        guard path.hasPrefix(prefix) else { return path }
        return (requestedRoot == "/" ? "/" : requestedRoot + "/") + path.dropFirst(prefix.count)
    }
}

private let eventStreamCallback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
    guard let info, count > 0 else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    var changes: [FileSystemChange] = []
    changes.reserveCapacity(count)
    for index in 0..<min(count, paths.count) {
        changes.append(FileSystemChange(path: box.reportedPath(paths[index]), flags: eventFlags[index]))
    }
    if !changes.isEmpty { box.handler(changes) }
}
