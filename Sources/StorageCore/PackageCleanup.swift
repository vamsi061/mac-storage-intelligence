import Darwin
import Foundation

private struct Wheel: Equatable, Sendable {
    let path: String
    let inode: ino_t
    let device: dev_t
    let size: off_t
    let changed: Int
    let nanoseconds: Int
}

public struct PackageTicket: Sendable {
    public let target: URL
    fileprivate let wheels: [Wheel]
    fileprivate let home: URL

    fileprivate var developer: DeveloperPackageTicket? = nil

    public var summary: String {
        if let developer { return developer.summary }
        let amount = ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
        return "Permanently remove \(wheels.count) cached pip wheel(s), \(amount) logical, under \(target.path)/wheels using pip cache remove '*-*'. Future installs may need to download or rebuild them. This bypasses Trash."
    }

    public var estimatedBytes: Int64 {
        if let developer { return developer.snapshot.bytes }
        return wheels.reduce(Int64(0)) { $0 + $1.size }
    }
}

public enum PackageCleanup {
    // Apple CLT supplies this interpreter and the matching pip distribution.
    private static let framework = "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9"
    private static let python = framework + "/bin/python3.9"
    private static let packages = framework + "/lib/python3.9/site-packages"

    public static func supports(_ match: CleanupRecommendation) -> Bool {
        if let tool = DeveloperCacheTool.allCases.first(where: { $0.rule == match.id }) {
            return match.risk != .protected && match.risk != .highRiskData && tool.installed() != nil
        }
        return match.id == "pip.cache" && match.risk == .regenerableCache &&
            FileManager.default.isExecutableFile(atPath: python)
    }

    public static func prepare(_ match: CleanupRecommendation) throws -> PackageTicket {
        guard supports(match) else { throw failure("This location requires review in its owning application.") }
        if let tool = DeveloperCacheTool.allCases.first(where: { $0.rule == match.id }) {
            let developer = try DeveloperPackageTicket.prepare(tool, cache: match.target)
            return PackageTicket(target: match.target, wheels: [], home: FileManager.default.homeDirectoryForCurrentUser, developer: developer)
        }
        return try prepare(target: match.target, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func prepare(target: URL, home: URL) throws -> PackageTicket {
        guard target.isFileURL, target.path == home.appendingPathComponent("Library/Caches/pip").path,
              let resolved = realpath(target.path, nil) else { throw failure("The standard pip cache is unavailable.") }
        defer { free(resolved) }
        guard String(cString: resolved) == target.path else { throw failure("The cache path contains a link or alias.") }
        guard try StorageActivitySnapshot.capture(candidates: [target]).protectionReason(for: target) == nil else {
            throw failure("The cache is currently in use.")
        }
        let wheels = try autoreleasepool { try inspectedWheels(at: target) }
        return PackageTicket(target: target, wheels: wheels, home: home)
    }

    private static func inspectedWheels(at target: URL) throws -> [Wheel] {
        let root = target.appendingPathComponent("wheels", isDirectory: true)
        let manager = FileManager.default
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
              rootInfo.st_uid == geteuid() else { throw failure("No user-owned pip wheel directory was found.") }
        var readFailed = false
        guard let walk = manager.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, _ in
            readFailed = true
            return false
        }) else { throw failure("The pip wheel directory could not be inspected.") }
        var wheels: [Wheel] = []
        for case let item as URL in walk {
            var info = stat()
            guard lstat(item.path, &info) == 0, info.st_dev == rootInfo.st_dev,
                  info.st_uid == geteuid(), info.st_mode & S_IFMT != S_IFLNK else {
                throw failure("A changed, linked, or inaccessible cache entry prevents cleanup.")
            }
            if info.st_mode & S_IFMT == S_IFDIR { continue }
            guard item.pathExtension == "whl" else { continue }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  item.lastPathComponent.contains("-"), wheels.count < 128 else {
                throw failure("This cache exceeds the supported set of ordinary wheel files.")
            }
            wheels.append(Wheel(path: item.path, inode: info.st_ino, device: info.st_dev, size: info.st_size,
                                changed: info.st_ctimespec.tv_sec, nanoseconds: info.st_ctimespec.tv_nsec))
        }
        guard !readFailed, !wheels.isEmpty else { throw failure("No accessible cached wheels were found.") }
        return wheels.sorted { $0.path < $1.path }
    }

    public static func execute(_ ticket: PackageTicket) throws -> String {
        if let developer = ticket.developer { return try developer.execute() }
        let verified = try prepare(target: ticket.target, home: ticket.home)
        guard verified.wheels == ticket.wheels else { throw failure("The cache changed. Review it again.") }
        for location in [python, packages + "/pip/__init__.py"] {
            guard let physical = realpath(location, nil) else { throw failure("Apple’s bundled pip is unavailable.") }
            defer { free(physical) }
            let path = String(cString: physical)
            guard path.hasPrefix(framework + "/") else { throw failure("Unexpected toolchain location.") }
            var url = URL(fileURLWithPath: path)
            while url.path != "/" {
                var attributes = stat()
                guard lstat(url.path, &attributes) == 0, attributes.st_uid == 0, attributes.st_mode & 0o022 == 0 else {
                    throw failure("The installed package tool has untrusted permissions.")
                }
                url.deleteLastPathComponent()
            }
        }
        // Kernel-enforced literal unlink permissions limit pip to the reviewed files,
        // including if its configuration, path resolution or matching behavior changes.
        let params = ticket.wheels.indices.map { "(literal (param \"W\($0)\"))" }.joined(separator: " ")
        let profile = "(version 1)(allow default)(deny network*)(deny file-write*)(allow file-write-data (literal (param \"CACHE\")))(allow file-write-unlink \(params))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        let bindings = ticket.wheels.enumerated().flatMap { ["-D", "W\($0.offset)=\($0.element.path)"] }
        let bootstrap = "import sys,runpy;sys.path.append(sys.argv.pop(1));runpy.run_module('pip',run_name='__main__')"
        process.arguments = ["-D", "CACHE=" + ticket.target.path] + bindings + ["-p", profile, python, "-I", "-S", "-B", "-c", bootstrap, packages,
                                        "--isolated", "--disable-pip-version-check", "--cache-dir", ticket.target.path,
                                        "cache", "remove", "*-*"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": ticket.home.path, "PIP_CONFIG_FILE": "/dev/null"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let before = try VolumeService().volume(containing: ticket.target).availableBytes
        try process.run()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(1024), as: UTF8.self)
        process.waitUntilExit()
        let removed = ticket.wheels.filter { wheel in
            var info = stat()
            return lstat(wheel.path, &info) != 0 && errno == ENOENT
        }.count
        let after = try? VolumeService().volume(containing: ticket.target).availableBytes
        let change = before.flatMap { old in after.map { "\($0 - old) bytes" } } ?? "unavailable"
        let report = "\(removed) of \(ticket.wheels.count) reviewed wheel files are gone. Observed volume free-space change: \(change). Other disk activity may affect this value."
        guard process.terminationStatus == 0 && removed == ticket.wheels.count else {
            throw failure("pip cleanup failed or was interrupted. \(errorText) \(report)")
        }
        return report
    }

    /// Executes independently confirmed official cleanups. Each ticket is revalidated by its
    /// own tool before deletion; partial success is reported instead of being hidden.
    public static func executeBatch(_ tickets: [PackageTicket]) throws -> String {
        guard !tickets.isEmpty else { throw failure("No supported cleanup locations were selected.") }
        var completed = 0
        var estimated: Int64 = 0
        var reports: [String] = []
        var failures: [String] = []
        for ticket in tickets {
            do {
                let detail = try execute(ticket)
                completed += 1
                let (sum, overflow) = estimated.addingReportingOverflow(ticket.estimatedBytes)
                estimated = overflow ? Int64.max : sum
                reports.append(ticket.target.path + ": " + detail)
            } catch {
                failures.append(ticket.target.path + ": " + error.localizedDescription)
            }
        }
        let size = ByteCountFormatter.string(fromByteCount: estimated, countStyle: .file)
        let summary = "\(completed) of \(tickets.count) official cache cleanups completed. Estimated selected size: \(size). " + reports.joined(separator: " ") +
            (failures.isEmpty ? "" : " Failures: " + failures.joined(separator: " "))
        guard failures.isEmpty, completed == tickets.count else { throw failure(summary) }
        return summary
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PackageCleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
