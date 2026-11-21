import Foundation

public struct ScanOptions: Sendable {
    public let largestFileLimit: Int
    public let directoryLimit: Int
    public let issueLimit: Int
    /// Absolute filesystem paths. Excluding a directory prunes its subtree.
    public let excludedPaths: Set<String>
    /// Levels below the scan root that are always retained for navigation, even after
    /// `directoryLimit` is reached. Incremental monitoring relies on a retained ancestor.
    public let minimumRetainedDepth: Int

    public init(
        largestFileLimit: Int = 100,
        directoryLimit: Int = 20_000,
        issueLimit: Int = 200,
        excludedPaths: Set<String> = [],
        minimumRetainedDepth: Int = 0
    ) {
        self.largestFileLimit = max(0, largestFileLimit)
        self.directoryLimit = max(1, directoryLimit)
        self.issueLimit = max(0, issueLimit)
        self.excludedPaths = excludedPaths
        self.minimumRetainedDepth = max(0, minimumRetainedDepth)
    }
}

public struct ScanProgress: Sendable {
    public let entriesVisited: Int
    public let logicalBytes: Int64
    public let currentPath: String
    public let filesMeasured: Int
    public let allocatedBytes: Int64
    public let issueCount: Int
}

struct ScanCounts: Sendable {
    var issues = 0
    var links = 0
    var mounts = 0
    var duplicates = 0
    var exclusions = 0
    var omissions = 0
    var retainedDirectories = 0

    mutating func add(_ other: Self, factor: Int = 1) {
        issues += other.issues * factor
        links += other.links * factor
        mounts += other.mounts * factor
        duplicates += other.duplicates * factor
        exclusions += other.exclusions * factor
        omissions += other.omissions * factor
        retainedDirectories += other.retainedDirectories * factor
    }
}

public struct DirectoryNode: Identifiable, Sendable {
    public var id: URL { url }
    public var unreadableEntryCount: Int { counts.issues }
    public let url: URL
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let fileCount: Int
    public let children: [DirectoryNode]
    public internal(set) var hasProtectedContent = false
    public internal(set) var projectMarkers: Set<String> = []
    var identity: FileIdentity?
    var counts = ScanCounts()
    var protectedOutsideChildren = false
}

public struct ScannedFile: Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let modifiedAt: Date?
}

public struct ScanIssue: Sendable {
    public let url: URL
    public let message: String
    public internal(set) var posixCode: Int32? = nil
}

public struct ScanResult: Sendable {
    public let root: DirectoryNode
    public let largestFiles: [ScannedFile]
    public let issues: [ScanIssue]
    public let issueCount: Int
    public let skippedLinks: Int
    public let skippedMounts: Int
    public let skippedDuplicates: Int
    public let excludedCount: Int
    public let omittedDirectories: Int
    public let completedAt: Date
    var linkedFileOwners: [FileIdentity: LinkedFileOwner] = [:]
}
