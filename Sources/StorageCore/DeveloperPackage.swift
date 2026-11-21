import CryptoKit
import Darwin
import Foundation

public enum DeveloperCacheTool: String, CaseIterable, Sendable {
    case npm, pnpm, yarn, uv, brew

    var relativePath: String {
        switch self {
        case .npm: return ".npm/_cacache"
        case .pnpm: return "Library/pnpm/store"
        case .yarn: return "Library/Caches/Yarn"
        case .uv: return ".cache/uv"
        case .brew: return "Library/Caches/Homebrew/downloads"
        }
    }
    var rule: String {
        switch self {
        case .npm: return "npm.content-cache"
        case .pnpm: return "pnpm.store"
        case .yarn: return "yarn.cache"
        case .uv: return "uv.cache"
        case .brew: return "homebrew.downloads"
        }
    }
    func invocation(cache: URL) -> [String] {
        switch self {
        case .npm: return ["--offline", "--ignore-scripts", "--cache", cache.deletingLastPathComponent().path, "cache", "clean", "--force"]
        case .pnpm: return ["--store-dir", cache.path, "store", "prune"]
        case .yarn: return ["--offline", "--ignore-scripts", "--no-default-rc", "--cache-folder", cache.path, "cache", "clean"]
        case .uv: return ["--offline", "--no-config", "--cache-dir", cache.path, "cache", "prune"]
        case .brew: return ["cleanup", "--prune=all"]
        }
    }

    // Never resolve a command against the app's inherited PATH, cwd, a project, or a shell.
    func installed() -> URL? {
        for prefix in ["/usr/local", "/opt/homebrew"] {
            let candidate = URL(fileURLWithPath: prefix + "/bin/" + rawValue)
            let resolved = candidate.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(prefix + "/"), FileManager.default.isExecutableFile(atPath: resolved.path),
                  resolved.path == candidate.path || resolved.path.hasPrefix(prefix + "/Cellar/") ||
                  resolved.path.hasPrefix(prefix + "/lib/node_modules/") || resolved.path.hasPrefix(prefix + "/Library/Homebrew/") else { continue }
            var info = stat()
            guard lstat(resolved.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  (info.st_uid == 0 || info.st_uid == getuid()), info.st_mode & 0o002 == 0 else { continue }
            return candidate
        }
        return nil
    }
}

struct DeveloperCacheSnapshot: Equatable, Sendable {
    let digest: Data
    let bytes: Int64
    let files: Int
    let paths: [String]

    static func capture(_ cache: URL, expected: URL) throws -> Self {
        guard cache.path == expected.path, cache.resolvingSymlinksInPath().path == cache.path else {
            throw DeveloperStorageError("This cache is outside the supported location or reached through a symbolic link.")
        }
        var root = stat()
        guard lstat(cache.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR, root.st_uid == getuid() else {
            throw DeveloperStorageError("A user-owned cache directory is required.")
        }
        var failed = false
        guard let walker = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil, errorHandler: { _, _ in
            failed = true; return false
        }) else { throw DeveloperStorageError("The cache could not be enumerated.") }
        var paths = [String]()
        var bytes: Int64 = 0
        var files = 0
        var checks = [String]()
        func fingerprint(_ path: String, _ info: stat) -> String {
            "\(path.utf8.count):\(path):\(info.st_dev):\(info.st_ino):\(info.st_gen):\(info.st_mode):\(info.st_size):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        }
        checks.append(fingerprint(cache.path, root))
        for case let url as URL in walker {
            try Task.checkCancellation()
            var info = stat()
            guard paths.count < 100_000, lstat(url.path, &info) == 0, info.st_dev == root.st_dev,
                  info.st_uid == getuid(), [S_IFDIR, S_IFREG].contains(info.st_mode & S_IFMT),
                  StorageFileKind.inferred(from: url.lastPathComponent) == .other else {
                throw DeveloperStorageError("A link, protected file, mount, ownership change, or inventory limit prevents cleanup.")
            }
            if info.st_mode & S_IFMT == S_IFREG { files += 1; bytes += info.st_size }
            paths.append(url.path)
            checks.append(fingerprint(url.path, info))
        }
        guard !failed else { throw DeveloperStorageError("Some cache entries could not be inspected.") }
        var hash = SHA256()
        for item in checks.sorted() { hash.update(data: Data((item + "\u{0}").utf8)) }
        return Self(digest: Data(hash.finalize()), bytes: bytes, files: files, paths: paths)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.digest == rhs.digest }
}

public struct DeveloperPackageTicket: Sendable {
    let tool: DeveloperCacheTool
    let executable: URL
    let resolved: URL
    let executableIdentity: String
    let cache: URL
    let snapshot: DeveloperCacheSnapshot
    public var summary: String {
        "Run the installed tool at \(executable.path) (\(resolved.path)) with arguments \(tool.invocation(cache: cache).joined(separator: " ")).\n\nThe selected cache contains \(snapshot.files) regular files, \(ByteCountFormatter.string(fromByteCount: snapshot.bytes, countStyle: .file)) logical. The command can permanently unlink entries within \(cache.path). Network access is disabled. Future builds may require downloads."
    }

    public static func prepare(_ tool: DeveloperCacheTool, cache: URL) throws -> Self {
        guard let executable = tool.installed() else { throw DeveloperStorageError("No supported installation of " + tool.rawValue + " was found.") }
        let resolved = executable.resolvingSymlinksInPath()
        var info = stat()
        guard lstat(resolved.path, &info) == 0 else { throw DeveloperStorageError("The executable changed.") }
        let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(tool.relativePath)
        let snapshot = try DeveloperCacheSnapshot.capture(cache, expected: expected)
        guard snapshot.files > 0, try StorageActivitySnapshot.capture(candidates: [cache]).protectionReason(for: cache) == nil else {
            throw DeveloperStorageError("This cache is empty or currently in use.")
        }
        return Self(tool: tool, executable: executable, resolved: resolved, executableIdentity: "\(info.st_ino):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)", cache: cache, snapshot: snapshot)
    }

    public func execute() throws -> String {
        let verified = try Self.prepare(tool, cache: cache)
        guard verified.snapshot == snapshot, verified.resolved == resolved, verified.executableIdentity == executableIdentity else {
            throw DeveloperStorageError("The tool or cache changed. Review the new inventory.")
        }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("msi-tool-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let prefix = executable.path.hasPrefix("/opt/homebrew/") ? "/opt/homebrew" : "/usr/local"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        // Only the tool's approved cache can lose entries. No writes to file contents there:
        // multiply linked package files may also be linked into live projects.
        let profile = """
        (version 1)
        (deny default)
        (allow process-fork sysctl-read file-read-metadata)
        (allow file-read* process-exec file-map-executable (subpath "/System") (subpath "/usr/bin") (subpath "/usr/lib") (subpath "/usr/share") (subpath "/bin") (subpath "/sbin") (subpath (param "PREFIX")))
        (allow file-read* (subpath "/dev") (subpath "/private/etc") (subpath (param "CACHE")) (subpath (param "SCRATCH")))
        (allow file-write* (subpath (param "SCRATCH")) (literal "/dev/null"))
        (allow file-write-unlink (subpath (param "CACHE")))
        (allow file-write-create (subpath (param "CACHE")))
        """
        var environment = ["PATH": prefix + "/bin:/usr/bin:/bin", "HOME": scratch.path, "TMPDIR": scratch.path,
                           "XDG_CONFIG_HOME": scratch.path, "COREPACK_ENABLE_NETWORK": "0", "COREPACK_ENABLE_PROJECT_SPEC": "0",
                           "NPM_CONFIG_USERCONFIG": "/dev/null", "NPM_CONFIG_GLOBALCONFIG": "/dev/null",
                           "NPM_CONFIG_LOGS_DIR": scratch.path, "YARN_IGNORE_PATH": "1", "CI": "1",
                           "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_AUTOREMOVE": "1", "HOMEBREW_NO_ANALYTICS": "1"]
        if tool == .brew { environment["HOMEBREW_CACHE"] = cache.deletingLastPathComponent().path }
        task.environment = environment
        task.arguments = ["-D", "PREFIX=" + prefix, "-D", "CACHE=" + cache.path, "-D", "SCRATCH=" + scratch.path, "-p", profile, executable.path] + tool.invocation(cache: cache)
        task.currentDirectoryURL = scratch
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardError = pipe
        let before = try? VolumeService().volume(containing: cache).availableBytes
        try task.run()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 60)
        timer.setEventHandler { if task.isRunning { task.terminate() } }
        timer.resume()
        defer { timer.cancel() }
        var errors = Data()
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            errors.append(data.prefix(max(0, 1024 - errors.count)))
        }
        task.waitUntilExit()
        var gone = 0
        for path in snapshot.paths {
            var info = stat()
            if lstat(path, &info) != 0, errno == ENOENT { gone += 1 }
        }
        let after = try? VolumeService().volume(containing: cache.deletingLastPathComponent()).availableBytes
        let delta = before.flatMap { b in after.map { " Observed volume free-space change: \($0 - b) bytes." } } ?? ""
        let report = "\(gone) of \(snapshot.paths.count) reviewed cache entries are gone." + delta
        guard task.terminationStatus == 0 else {
            throw DeveloperStorageError("The installed tool could not complete the scoped operation. " + String(decoding: errors, as: UTF8.self) + " " + report)
        }
        return report
    }
}
