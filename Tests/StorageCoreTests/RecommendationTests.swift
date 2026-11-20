import Foundation
#if !STORAGE_FIXTURE_RUNNER
@testable import StorageCore
import XCTest
#endif

enum RecommendationChecks {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
        if !condition() { throw Failure(reason) }
    }

    private static func directory(_ path: String, _ size: Int64 = 4_096, children: [DirectoryNode] = []) -> DirectoryNode {
        DirectoryNode(url: URL(fileURLWithPath: path, isDirectory: true), logicalBytes: size * 2,
                      allocatedBytes: size, fileCount: size > 0 ? 1 : 0, children: children)
    }

    private static func scan(_ root: DirectoryNode, issues: Int = 0, omitted: Int = 0) -> ScanResult {
        ScanResult(root: root, largestFiles: [], issues: [], issueCount: issues, skippedLinks: 0, skippedMounts: 0,
                   skippedDuplicates: 0, excludedCount: 0, omittedDirectories: omitted,
                   completedAt: Date(timeIntervalSince1970: 0))
    }

    static func run() throws {
        let kinds: [(String, StorageFileKind)] = [
            ("report.pages", .document), ("history.SQLite", .database), ("profile.sqlite-WAL", .database),
            ("PG_VERSION", .database), ("work.qcow2", .virtualMachine), ("backup.dmg", .diskImage),
            ("weights.safetensors", .model), ("app.cache", .other)
        ]
        for (name, kind) in kinds {
            let item = ScannedFile(url: URL(fileURLWithPath: "/fixture/" + name),
                                   logicalBytes: 1, allocatedBytes: 1, modifiedAt: nil)
            try require(item.storageKind == kind, "Unexpected storage kind for " + name)
        }
        let homePath = "/Users/recommendation-fixture"
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        let registry = CleanupRuleRegistry()
        let suffixes = [
            ".npm/_cacache", "Library/Developer/Xcode/DerivedData", "Library/Caches/pip",
            ".cache/uv", "Library/Caches/Homebrew/downloads", ".ollama/models", ".cache/huggingface/hub"
        ]
        let download = directory(homePath + "/Downloads")
        let files = ["old.tmp", "old.log", "resume.part", "today.tmp", "notes.txt"].map { name in
            ScannedFile(url: download.url.appendingPathComponent(name), logicalBytes: 1024, allocatedBytes: 512,
                        modifiedAt: name == "today.tmp" ? Date() : Date(timeIntervalSince1970: 0))
        }
        let oldFiles = ScanResult(root: download, largestFiles: files, issues: [], issueCount: 0, skippedLinks: 0,
                                  skippedMounts: 0, skippedDuplicates: 0, excludedCount: 0, omittedDirectories: 0,
                                  completedAt: Date())
        let oldMatches = registry.recommendations(for: oldFiles, home: home,
                                                  activity: StorageActivitySnapshot(activeDirectories: [files[1].url]))
        try require(Set(oldMatches.map { $0.target.lastPathComponent }) == ["old.tmp", "old.log", "resume.part"],
                    "File age and scope must constrain temporary and log matches")
        try require(oldMatches.first { $0.target == files[1].url }?.risk == .protected,
                    "An active log file was suggested for cleanup")
        let candidates = suffixes.enumerated().map { offset, path in
            directory(homePath + "/" + path, Int64(offset + 1) * 1_024)
        }
        let valid = registry.recommendations(for: scan(directory(homePath, children: candidates)), home: home)
        try require(valid.count == 7 && Set(valid.map(\.id)).count == 7, "Expected seven distinct standard locations")
        try require(valid.map(\.allocatedBytes) == (1...7).reversed().map { Int64($0 * 1_024) }, "Incorrect ranked allocation")
        try require(valid.allSatisfy { $0.logicalBytes == $0.allocatedBytes * 2 && $0.fileCount == 1 }, "Lost observed totals")
        let assets = valid.filter { $0.risk == .highRiskData }
        try require(Set(assets.map(\.id)) == ["ollama.models", "huggingface.hub"], "Model assets must have high risk")
        try require(assets.allSatisfy { $0.estimatedRecoveryRange == nil }, "Model data received an automatic savings estimate")
        try require(valid.filter { $0.risk != .highRiskData }.allSatisfy {
            $0.estimatedRecoveryRange == 0...$0.allocatedBytes
        }, "Estimated range did not reflect uncertainty and observed allocation")
        try require(valid.allSatisfy {
            !$0.nextAction.isEmpty && !$0.applicationGuidance.isEmpty && !$0.consequences.isEmpty &&
                !$0.regeneration.isEmpty && $0.inUseStatus.hasPrefix("Unknown")
        }, "Missing review guidance or unknown activity status")

        let expanded: [(String, String, CleanupRisk)] = [
            ("pnpm.store", "Library/pnpm/store", .reviewRecommended),
            ("gradle.caches", ".gradle/caches", .reviewRecommended),
            ("docker.desktop-vms", "Library/Containers/com.docker.docker/Data/vms", .highRiskData),
            ("colima.profiles", ".colima", .highRiskData),
            ("chrome.cache", "Library/Caches/Google/Chrome", .regenerableCache),
            ("safari.cache", "Library/Caches/com.apple.Safari", .reviewRecommended),
            ("user.documents", "Documents", .protected)
        ]
        for (id, path, risk) in expanded {
            let candidate = directory(homePath + "/" + path)
            let observation = scan(candidate)
            let row = registry.recommendations(for: observation, home: home).first
            try require(row?.id == id && row?.risk == risk, "Wrong classification for " + path)
            try require((row?.estimatedRecoveryRange != nil) == (risk == .regenerableCache || risk == .reviewRecommended),
                        "Wrong recovery policy for " + path)
            let busy = StorageActivitySnapshot(activeDirectories: [candidate.url])
            let active = registry.recommendations(for: observation, home: home, activity: busy).first
            try require(active?.risk == .protected && active?.estimatedRecoveryRange == nil, "Ignored active target " + path)
        }
        let guarded = DirectoryNode(url: candidates[0].url, logicalBytes: 200, allocatedBytes: 128,
                                    fileCount: 1, children: [], hasProtectedContent: true)
        let sensitive = registry.recommendations(for: scan(guarded), home: home).first
        try require(sensitive?.risk == .protected && sensitive?.estimatedRecoveryRange == nil,
                    "A protected file inside a cache received a recovery estimate")
        let lookalikes = [
            homePath + "/project/.npm/_cacache", homePath + "/Library/Caches/pip-old",
            homePath + "/tmp/../.cache/uv", homePath + "//.cache/uv", homePath + "/.cache/./uv",
            homePath + "/Library/Developer/Xcode/Archives", homePath + "/.npm",
            homePath + "-another/.cache/uv", homePath + "/Library/Caches/Homebrew",
            homePath + "/.ollama/models/family", "/System/Library/Caches/pip"
        ].map { directory($0) }
        try require(registry.recommendations(for: scan(directory(homePath, children: lookalikes)), home: home).isEmpty,
                    "Matched a lookalike, broader directory, component traversal or unrelated account")

        for invalidHome in ["/", "/Users", "/Users/Shared", "/Users/shared", "/Users/.system",
                            "/System", "/Library", "/etc", "/private/var/root", "/System/Volumes/Preboot",
                            "/Users/fake/../real", "/Users/real/Library/Containers/example/Data"] {
            let root = directory(invalidHome, children: [directory(invalidHome + "/.ollama/models")])
            try require(registry.recommendations(for: scan(root), home: root.url).isEmpty,
                        "A protected or unsupported home matched: \(invalidHome)")
        }
        let unrelated = directory("/Users/different", children: candidates)
        try require(registry.recommendations(for: scan(unrelated), home: home).isEmpty, "Escaped the selected scan root")

        let partial = registry.recommendations(for: scan(candidates[0], issues: 3, omitted: 9), home: home)
        try require(partial.count == 1 && partial[0].id == "npm.content-cache", "Could not classify selected cache itself")
        try require(partial[0].coverageNote.contains("errors") && partial[0].coverageNote.contains("display limit"),
                    "Partial enumeration or retained-directory limit was concealed")
        try require(partial[0].allocatedBytes == 1_024, "Directory display truncation changed the observed aggregate")
        let clipped = directory(homePath, 123_456, children: [])
        try require(registry.recommendations(for: scan(clipped, omitted: 9), home: home).isEmpty,
                    "Inferred an unseen cache from its parent's size")
        let empty = directory(homePath + "/.cache/uv", 0)
        try require(registry.recommendations(for: scan(empty), home: home).isEmpty, "Suggested an empty directory")

        let tied = candidates.map { directory($0.url.path) }
        let a = registry.recommendations(for: scan(directory(homePath, children: tied)), home: home)
        let b = registry.recommendations(for: scan(directory(homePath, children: Array(tied.reversed()) + tied)), home: home)
        try require(a.map(\.id) == b.map(\.id) && b.map(\.id) == b.map(\.id).sorted(),
                    "Repeated nodes or enumeration order changed the preview")
    }
}

#if !STORAGE_FIXTURE_RUNNER
final class CleanupRecommendationTests: XCTestCase {
    func testDiscoveryRiskCoverageAndBoundaries() throws { try RecommendationChecks.run() }
}
#endif
