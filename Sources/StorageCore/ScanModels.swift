import Foundation

public struct ScanOptions: Sendable {
    public let largestFileLimit: Int
    public let directoryLimit: Int
    public let issueLimit: Int
    /// Absolute filesystem paths. Excluding a directory prunes its subtree.
    public let excludedPaths: Set<String>

    public init(
        largestFileLimit: Int = 100,
        directoryLimit: Int = 20_000,
        issueLimit: Int = 200,
        excludedPaths: Set<String> = []
    ) {
        self.largestFileLimit = max(0, largestFileLimit)
        self.directoryLimit = max(1, directoryLimit)
        self.issueLimit = max(0, issueLimit)
        self.excludedPaths = excludedPaths
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

public struct DirectoryNode: Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let fileCount: Int
    public let children: [DirectoryNode]
    public internal(set) var hasProtectedContent = false
    public internal(set) var projectMarkers: Set<String> = []
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
}
