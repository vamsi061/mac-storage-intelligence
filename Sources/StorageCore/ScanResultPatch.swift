import Foundation

/// Applies a freshly measured subtree to an existing result without rescanning the whole root.
/// Only the path from the root to the updated folder is rebuilt; sibling branches are retained.
public extension ScanResult {
    /// The deepest retained folder whose path is `path` itself or one of its ancestors.
    func deepestDirectory(containing path: String) -> DirectoryNode? {
        let target = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard target == root.url.path || target.hasPrefix(root.url.path == "/" ? "/" : root.url.path + "/") else {
            return nil
        }
        var current = root
        while current.url.path != target {
            let prefix = current.url.path == "/" ? "/" : current.url.path + "/"
            guard target.hasPrefix(prefix),
                  let child = current.children
                    .filter({ target == $0.url.path || target.hasPrefix($0.url.path + "/") })
                    .max(by: { $0.url.path.count < $1.url.path.count }) else { return current }
            current = child
        }
        return current
    }

    /// Replaces the folder at `target` with `replacement` and folds the difference into every
    /// ancestor. Returns nil when the target is not retained in this result or the totals overflow.
    func replacingSubtree(
        at target: URL,
        with replacement: DirectoryNode,
        largestFiles newFiles: [ScannedFile],
        issues newIssues: [ScanIssue],
        issueLimit: Int = 200
    ) -> ScanResult? {
        guard target.isFileURL, replacement.url.path == target.path,
              let merged = Self.fold(node: root, targetPath: target.path, replacement: replacement) else {
            return nil
        }
        let prefix = target.path == "/" ? "/" : target.path + "/"

        // A file outside each changed subtree can only enter the global list if it entered that
        // subtree's list, so merging the retained candidates is conservative. Files that were
        // previously ranked below the global cut are restored by the next full verification.
        var files = largestFiles.filter { !($0.url.path == target.path || $0.url.path.hasPrefix(prefix)) }
        files.append(contentsOf: newFiles)
        files.sort(by: Self.ranksBefore)
        // The exact retained limit is not stored on the result; 200 bounds the merge until the
        // next full verification trims the list to the configured limit.
        files = Array(files.prefix(200))

        var issues = issues.filter { !($0.url.path == target.path || $0.url.path.hasPrefix(prefix)) }
        issues.append(contentsOf: newIssues)
        if issues.count > issueLimit { issues = Array(issues.prefix(issueLimit)) }

        return ScanResult(
            root: merged,
            largestFiles: files,
            issues: issues,
            // The retained issue count is authoritative for the last full verification.
            issueCount: max(issueCount, issues.count),
            skippedLinks: skippedLinks,
            skippedMounts: skippedMounts,
            skippedDuplicates: skippedDuplicates,
            excludedCount: excludedCount,
            omittedDirectories: omittedDirectories,
            completedAt: completedAt, linkedFileOwners: linkedFileOwners
        )
    }

    internal func mergingRefresh(
        previous: DirectoryNode, measurement: ScanResult, reused: Set<String>, options: ScanOptions
    ) -> ScanResult? {
        let target = previous.url.path
        let prefix = target == "/" ? "/" : target + "/"
        func keepOldEntry(_ path: String) -> Bool {
            guard path != target else { return false }
            guard path.hasPrefix(prefix) else { return true }
            let suffix = path.dropFirst(prefix.count)
            let name = suffix.prefix { $0 != "/" }
            return reused.contains(prefix + name)
        }
        guard let merged = Self.fold(node: root, targetPath: target, replacement: measurement.root) else {
            return nil
        }
        let files = (largestFiles.filter { keepOldEntry($0.url.path) } + measurement.largestFiles)
            .sorted(by: Self.ranksBefore)
        let retainedIssues = issues.filter { keepOldEntry($0.url.path) } + measurement.issues
        let counts = merged.counts
        return ScanResult(root: merged, largestFiles: Array(files.prefix(options.largestFileLimit)),
                          issues: Array(retainedIssues.prefix(options.issueLimit)), issueCount: counts.issues,
                          skippedLinks: counts.links, skippedMounts: counts.mounts,
                          skippedDuplicates: counts.duplicates, excludedCount: counts.exclusions,
                          omittedDirectories: counts.omissions, completedAt: completedAt,
                          linkedFileOwners: measurement.linkedFileOwners)
    }

    private static func ranksBefore(_ a: ScannedFile, _ b: ScannedFile) -> Bool {
        if a.logicalBytes != b.logicalBytes { return a.logicalBytes > b.logicalBytes }
        return a.url.path < b.url.path
    }

    private static func fold(
        node: DirectoryNode, targetPath: String, replacement: DirectoryNode
    ) -> DirectoryNode? {
        if node.url.path == targetPath { return replacement }
        let prefix = node.url.path == "/" ? "/" : node.url.path + "/"
        guard targetPath.hasPrefix(prefix) else { return nil }

        for index in node.children.indices {
            let child = node.children[index]
            guard targetPath == child.url.path || targetPath.hasPrefix(child.url.path + "/"),
                  let updated = fold(node: child, targetPath: targetPath, replacement: replacement) else {
                continue
            }
            let (logical, logicalOverflow) = node.logicalBytes.addingReportingOverflow(
                updated.logicalBytes - child.logicalBytes)
            let (allocated, allocatedOverflow) = node.allocatedBytes.addingReportingOverflow(
                updated.allocatedBytes - child.allocatedBytes)
            let (count, countOverflow) = node.fileCount.addingReportingOverflow(
                updated.fileCount - child.fileCount)
            guard !logicalOverflow, !allocatedOverflow, !countOverflow else { return nil }

            var children = node.children
            children[index] = updated
            children.sort {
                if $0.logicalBytes != $1.logicalBytes { return $0.logicalBytes > $1.logicalBytes }
                return $0.url.path < $1.url.path
            }
            var merged = DirectoryNode(
                url: node.url, logicalBytes: logical, allocatedBytes: allocated,
                fileCount: count, children: children
            )
            merged.protectedOutsideChildren = node.protectedOutsideChildren
            merged.hasProtectedContent = node.protectedOutsideChildren || children.contains(where: \.hasProtectedContent)
            merged.projectMarkers = node.projectMarkers
            merged.identity = node.identity
            merged.counts = node.counts
            merged.counts.add(child.counts, factor: -1)
            merged.counts.add(updated.counts)
            return merged
        }
        return nil
    }
}
