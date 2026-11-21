import Darwin
import Foundation

/// Resolves the launch scan root without assuming a home path or trusting stale preferences.
/// macOS can expose firmlink paths such as `/System/Volumes/Data/home`; those are system
/// locations, not the signed-in account's home, and must never become a resume target.
public struct ScanRootResolver: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.standardizedFileURL
    }

    /// The current account home, resolved dynamically by Foundation.
    public var defaultRoot: URL { home }

    public struct StoredRootValidation: Sendable, Equatable {
        public let url: URL?
        public let rejection: String?
        public init(url: URL?, rejection: String?) {
            self.url = url
            self.rejection = rejection
        }
    }

    /// Accepts only an existing local directory that is not a macOS-managed system root.
    public func validateStoredRoot(_ stored: String?) -> StoredRootValidation {
        guard let raw = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return StoredRootValidation(url: nil, rejection: nil)
        }
        guard raw.hasPrefix("/"), !raw.utf8.contains(0) else {
            return StoredRootValidation(url: nil, rejection: "The saved folder path is not a local absolute path.")
        }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        guard url.isFileURL, url.baseURL == nil else {
            return StoredRootValidation(url: nil, rejection: "The saved folder path is not a local absolute path.")
        }
        let path = url.standardizedFileURL.path
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains("."), !components.contains("..") else {
            return StoredRootValidation(url: nil, rejection: "The saved folder path is ambiguous.")
        }
        let systemRoots = ["/System", "/private", "/usr", "/bin", "/sbin", "/etc", "/dev", "/cores", "/Library"]
        if path == "/" || systemRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return StoredRootValidation(url: nil, rejection: "The saved folder is a macOS-managed system location, not a user folder.")
        }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return StoredRootValidation(url: nil, rejection: "The saved folder no longer exists.")
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return StoredRootValidation(url: nil, rejection: "The saved scan target is not a folder.")
        }
        guard access(path, R_OK | X_OK) == 0 else {
            return StoredRootValidation(url: nil, rejection: "The saved folder is not readable by this account.")
        }
        return StoredRootValidation(url: URL(fileURLWithPath: path, isDirectory: true), rejection: nil)
    }
}

/// A breakdown that keeps volume capacity authoritative and reports measured data separately.
/// Roots that contain one another are counted once; APFS shared/reserved blocks are never added
/// to the used total a second time.
public struct StorageBreakdown: Sendable, Equatable {
    public struct MeasuredRoot: Sendable, Equatable {
        public let url: URL
        public let allocatedBytes: Int64
        public init(url: URL, allocatedBytes: Int64) {
            self.url = url
            self.allocatedBytes = max(0, allocatedBytes)
        }
    }

    public let totalBytes: Int64
    public let availableBytes: Int64
    public let usedBytes: Int64
    public let sharedBytes: Int64
    public let measuredUserBytes: Int64
    public let measuredAccessibleBytes: Int64
    public let recoverableBytes: Int64
    public let recoverableItems: Int
    public let unmeasuredBytes: Int64
    public let measuredRootCount: Int

    public init(volume: StorageVolume?, primaryRoot: MeasuredRoot?,
                additionalRoots: [MeasuredRoot] = [], recoverableBytes: Int64 = 0,
                recoverableItems: Int = 0) {
        let total = max(0, volume?.totalBytes ?? 0)
        let available = min(total, max(0, volume?.availableBytes ?? 0))
        let used = min(max(0, volume?.usedBytes ?? 0), total)
        totalBytes = total
        availableBytes = available
        usedBytes = used
        sharedBytes = max(0, total - available - used)

        var accepted: [MeasuredRoot] = []
        func overlaps(_ lhs: String, _ rhs: String) -> Bool {
            lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
        }
        if let primaryRoot {
            accepted.append(primaryRoot)
        }
        for root in additionalRoots.sorted(by: { $0.url.path.count < $1.url.path.count }) {
            guard !accepted.contains(where: { overlaps($0.url.path, root.url.path) }) else { continue }
            accepted.append(root)
        }
        measuredRootCount = accepted.count
        let totalMeasured = accepted.reduce(Int64(0)) { sum, root in
            let (next, overflow) = sum.addingReportingOverflow(root.allocatedBytes)
            return overflow ? Int64.max : next
        }
        measuredAccessibleBytes = min(used, totalMeasured)
        measuredUserBytes = min(used, primaryRoot?.allocatedBytes ?? 0)
        unmeasuredBytes = max(0, used - measuredAccessibleBytes)
        self.recoverableBytes = min(used, max(0, recoverableBytes))
        self.recoverableItems = max(0, recoverableItems)
    }
}
