import Foundation

public enum CleanupRisk: String, Sendable {
    case regenerableCache, reviewRecommended, highRiskData, protected

    public var label: String {
        switch self {
        case .regenerableCache: return "Safe to Clean"
        case .reviewRecommended: return "Review Required"
        case .highRiskData: return "Protected · application data"
        case .protected: return "Protected"
        }
    }

    fileprivate var severity: Int {
        switch self {
        case .regenerableCache: return 0
        case .reviewRecommended: return 1
        case .highRiskData: return 2
        case .protected: return 3
        }
    }
}

public struct CleanupRecommendation: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let target: URL
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let fileCount: Int
    public let risk: CleanupRisk
    public let reason: String
    public let consequences: String
    public let regeneration: String
    public let applicationGuidance: String
    public let nextAction: String
    public let coverageNote: String

    public var confidence: String { "Default path match. Ownership and contents need confirmation." }
    public let inUseStatus: String

    /// Indicative only, restricted to the regular-file data observed at this exact path.
    public var estimatedRecoveryRange: ClosedRange<Int64>? {
        switch risk {
        case .regenerableCache, .reviewRecommended: return 0...allocatedBytes
        case .highRiskData, .protected: return nil
        }
    }

    public var recoveryEstimate: String {
        if risk == .protected { return "Withheld for this protected location." }
        guard let range = estimatedRecoveryRange else {
            return "Choose individual assets and verify backups before estimating recovery."
        }
        let size = ByteCountFormatter.string(fromByteCount: range.upperBound, countStyle: .decimal)
        return "Roughly zero to \(size) for the measured files. Tool eligibility, shared blocks, links and snapshots affect actual recovery."
    }
}

private struct CleanupRule {
    let id: String
    let title: String
    let path: String
    let risk: CleanupRisk
    let consequences: String
    let regeneration: String
    let applicationGuidance: String
    let nextAction: String
}

public struct CleanupRuleRegistry: Sendable {
    public init() {}

    private static let rules = [
        CleanupRule(
            id: "npm.content-cache", title: "npm package cache", path: ".npm/_cacache", risk: .regenerableCache,
            consequences: "Offline installs may lose access to cached package data.",
            regeneration: "npm can fetch packages again while their registry and versions remain available.",
            applicationGuidance: "Wait for npm installs and builds to finish.",
            nextAction: "Inspect packages with npm cache ls. Use npm’s own cache management for maintenance."
        ),
        CleanupRule(
            id: "xcode.derived-data", title: "Xcode Derived Data", path: "Library/Developer/Xcode/DerivedData", risk: .reviewRecommended,
            consequences: "Removing project data discards build products, indexes and any build or test logs stored here.",
            regeneration: "Builds recreate outputs and indexes. Preserve historical logs or unique build products separately.",
            applicationGuidance: "Finish builds and tests, then close the affected Xcode projects.",
            nextAction: "Review each project in Xcode’s Derived Data location and keep any results you need."
        ),
        CleanupRule(
            id: "pip.cache", title: "pip package cache", path: "Library/Caches/pip", risk: .regenerableCache,
            consequences: "Future installs may need a download or a local wheel build.",
            regeneration: "pip can download or build wheels again while the sources and build tools remain available.",
            applicationGuidance: "Wait for active pip installations to finish.",
            nextAction: "Review the configured cache with pip cache info and inspect individual wheels with pip cache list."
        ),
        CleanupRule(
            id: "uv.cache", title: "uv package cache", path: ".cache/uv", risk: .reviewRecommended,
            consequences: "Pruning can remove unused artifacts and centrally stored project environments. Cache-linked environments may depend on retained files.",
            regeneration: "Rebuilding environments and wheels can require network access, source packages and build tools.",
            applicationGuidance: "Finish uv activity and check which environments use the cache.",
            nextAction: "Confirm the location with uv cache dir. Review uv’s cache prune behavior for your installed version."
        ),
        CleanupRule(
            id: "homebrew.downloads", title: "Homebrew downloads", path: "Library/Caches/Homebrew/downloads", risk: .regenerableCache,
            consequences: "Removing a cached download may require fetching a bottle or source archive again.",
            regeneration: "Homebrew can fetch artifacts that remain available upstream.",
            applicationGuidance: "Wait for active Homebrew installations and upgrades to finish.",
            nextAction: "Use brew cleanup --dry-run to inspect Homebrew’s proposed changes, including items outside this folder."
        ),
        CleanupRule(
            id: "ollama.models", title: "Ollama model storage", path: ".ollama/models", risk: .highRiskData,
            consequences: "Removing a model can interrupt offline inference and lose locally created model data.",
            regeneration: "Published models may be downloadable. Local or private models require a verified source or backup.",
            applicationGuidance: "Check running models with ollama ps and finish dependent inference jobs.",
            nextAction: "Review installed models with ollama list and preserve custom models before choosing individual items."
        ),
        CleanupRule(
            id: "huggingface.hub", title: "Hugging Face Hub assets", path: ".cache/huggingface/hub", risk: .highRiskData,
            consequences: "Models, datasets and revisions used by offline workflows may become unavailable.",
            regeneration: "Restoring a revision requires continued repository access or a separate backup.",
            applicationGuidance: "Finish training, inference and downloads that use these assets.",
            nextAction: "Inspect cached repositories and revisions with hf cache ls before selecting individual assets."
        ),
        CleanupRule(
            id: "pnpm.store", title: "pnpm package store", path: "Library/pnpm/store", risk: .reviewRecommended,
            consequences: "Removing packages can affect offline installs and require new downloads.",
            regeneration: "Available registry packages can be fetched again.",
            applicationGuidance: "Wait for package installations to finish.",
            nextAction: "Review the active location with pnpm store path and inspect pnpm store status."
        ),
        CleanupRule(
            id: "gradle.caches", title: "Gradle caches", path: ".gradle/caches", risk: .reviewRecommended,
            consequences: "Rebuilding artifacts takes time and offline builds may lose dependencies.",
            regeneration: "Gradle can resolve published dependencies and regenerate build outputs.",
            applicationGuidance: "Finish builds and stop affected Gradle daemons.",
            nextAction: "Review Gradle’s cache retention settings and project requirements."
        ),
        CleanupRule(
            id: "docker.desktop-vms", title: "Docker Desktop virtual machines", path: "Library/Containers/com.docker.docker/Data/vms", risk: .highRiskData,
            consequences: "Removing a VM can destroy local containers, volumes and databases.",
            regeneration: "Local volume contents require an independent backup.",
            applicationGuidance: "Check Docker Desktop for running containers.",
            nextAction: "Review disk usage in Docker Desktop and back up important volumes."
        ),
        CleanupRule(
            id: "colima.profiles", title: "Colima virtual machines and profiles", path: ".colima", risk: .highRiskData,
            consequences: "A profile may hold a virtual disk, container volumes and cluster state.",
            regeneration: "Local workloads and volumes require backups.",
            applicationGuidance: "Check running profiles with colima list.",
            nextAction: "Review each profile and back up its persistent data."
        ),
        CleanupRule(
            id: "chrome.cache", title: "Google Chrome browser cache", path: "Library/Caches/Google/Chrome", risk: .regenerableCache,
            consequences: "Offline pages and cached resources may need downloading again.",
            regeneration: "Chrome refetches resources while their sources remain available.",
            applicationGuidance: "Finish downloads and close Chrome before maintenance.",
            nextAction: "Review cached files in Chrome’s browsing data settings."
        ),
        CleanupRule(
            id: "safari.cache", title: "Safari application cache", path: "Library/Caches/com.apple.Safari", risk: .reviewRecommended,
            consequences: "Offline resources and application cache state may be lost.",
            regeneration: "Safari can recreate many cached resources while sources remain available.",
            applicationGuidance: "Close Safari before any maintenance.",
            nextAction: "Review Safari’s website data controls."
        ),
        CleanupRule(
            id: "user.documents", title: "User documents", path: "Documents", risk: .protected,
            consequences: "Documents may contain unique work and application libraries.",
            regeneration: "Recovery requires an independent backup.",
            applicationGuidance: "Review edited documents in the owning application.",
            nextAction: "Review individual documents in Finder and preserve personal work."
        )
    ]

    /// Classifies retained directory observations. This code performs no filesystem I/O.
    public func recommendations(
        for scan: ScanResult, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        activity: StorageActivitySnapshot = .unknown
    ) -> [CleanupRecommendation] {
        guard let homePath = Self.canonicalPath(home), Self.isIndividualHome(homePath),
              let rootPath = Self.canonicalPath(scan.root.url) else { return [] }

        let targets = Dictionary(uniqueKeysWithValues: Self.rules.map { (homePath + "/" + $0.path, $0) })
        // Only inspect branches leading to a configured location. Component boundaries distinguish
        // similarly named folders such as "Cache" and "CacheBackup".
        var ancestors = Set(targets.keys)
        for target in targets.keys {
            var path = target[...]
            while let separator = path.lastIndex(of: "/") {
                path = path[..<separator]
                ancestors.insert(path.isEmpty ? "/" : String(path))
            }
        }
        guard ancestors.contains(rootPath) || rootPath.hasPrefix(homePath + "/") else { return [] }

        var stack = [scan.root]
        var found: [CleanupRecommendation] = []
        var seen: Set<String> = []
        let coverage = Self.coverageDescription(scan)
        while let node = stack.popLast() {
            let path = node.url.path
            guard ancestors.contains(path), Self.canonicalPath(node.url) == path,
                  seen.insert(path).inserted else { continue }
            if let rule = targets[path], node.fileCount > 0,
               node.allocatedBytes >= 0, node.logicalBytes >= 0, node.allocatedBytes > 0 || node.logicalBytes > 0 {
                let active = activity.protectionReason(for: node.url)
                var reasons = ["The scan found files at ~/\(rule.path), the standard location for \(rule.title)."]
                if let active { reasons.append(active) }
                if node.hasProtectedContent {
                    reasons.append("The scanner found sensitive content or incomplete coverage in this folder.")
                }
                let risk: CleanupRisk = active != nil || node.hasProtectedContent ? .protected : rule.risk
                found.append(CleanupRecommendation(
                    id: rule.id, title: rule.title, target: node.url, logicalBytes: node.logicalBytes,
                    allocatedBytes: node.allocatedBytes, fileCount: node.fileCount, risk: risk,
                    reason: reasons.joined(separator: " "),
                    consequences: rule.consequences, regeneration: rule.regeneration,
                    applicationGuidance: rule.applicationGuidance, nextAction: risk == .protected ? "Keep this location intact. Review its contents in the owning application." : rule.nextAction, coverageNote: coverage,
                    inUseStatus: active ?? "Unknown. Process visibility is limited and activity can change."
                ))
            }
            let prefix = path == "/" ? "/" : path + "/"
            stack.append(contentsOf: node.children.filter {
                ancestors.contains($0.url.path) && $0.url.path.hasPrefix(prefix)
            })
        }

        // Only present measured files. A suffix or age alone cannot establish disposability.
        for file in scan.largestFiles {
            guard let path = Self.canonicalPath(file.url), path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/"),
                  let date = file.modifiedAt, scan.completedAt.timeIntervalSince(date) >= 30 * 86_400,
                  file.logicalBytes > 0 else { continue }
            let parent = file.url.deletingLastPathComponent().path
            let ext = file.url.pathExtension.lowercased()
            let personal = [homePath + "/Downloads", homePath + "/Desktop"].contains(parent)
            let log = ext == "log" && (personal || parent == homePath + "/Library/Logs" || parent.hasPrefix(homePath + "/Library/Logs/"))
            let temporary = ["tmp", "temp", "part"].contains(ext) && personal
            guard log || temporary else { continue }
            let active = activity.protectionReason(for: file.url)
            found.append(CleanupRecommendation(
                id: (log ? "user.log-file:" : "user.temp-file:") + path, title: file.url.lastPathComponent,
                target: file.url, logicalBytes: file.logicalBytes, allocatedBytes: file.allocatedBytes, fileCount: 1,
                risk: active == nil ? .reviewRecommended : .protected,
                reason: "This measured file has a " + (log ? "log" : "temporary-file") + " suffix and was last modified at least 30 days before the scan.",
                consequences: log ? "Removing it loses diagnostic history." : "Removing it can prevent resuming unfinished work or a download.",
                regeneration: "Historical contents may be unique.", applicationGuidance: "Finish any task using the file.",
                nextAction: "Inspect the file and confirm before moving it to Trash.", coverageNote: coverage,
                inUseStatus: active ?? "Unknown. Process visibility is limited and activity can change."
            ))
        }

        // If future rules overlap, keep the higher-risk observation. A tied risk uses the narrower
        // target. Neither the preview nor a caller summing its rows will count a subtree twice.
        found.sort {
            if $0.risk != $1.risk { return $0.risk.severity > $1.risk.severity }
            if $0.target.path.count != $1.target.path.count { return $0.target.path.count > $1.target.path.count }
            return $0.id < $1.id
        }
        var disjoint: [CleanupRecommendation] = []
        for match in found {
            let path = match.target.path
            if !disjoint.contains(where: { path.hasPrefix($0.target.path + "/") || $0.target.path.hasPrefix(path + "/") }) {
                disjoint.append(match)
            }
        }
        return disjoint.sorted {
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            return $0.id < $1.id
        }
    }

    private static func canonicalPath(_ url: URL) -> String? {
        guard url.isFileURL, url.baseURL == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              (components.host ?? "").isEmpty || components.host == "localhost",
              components.query == nil, components.fragment == nil, components.port == nil,
              components.user == nil, components.password == nil,
              !components.percentEncodedPath.lowercased().contains("%2f") else { return nil }
        let path = components.path
        guard path.hasPrefix("/"), !path.contains("//"), !path.utf8.contains(0),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func isIndividualHome(_ path: String) -> Bool {
        // The initial registry supports standard local account homes. This allowlist also rules
        // out the system volume, /Library, /private, volume roots and containerized app homes.
        let components = path.split(separator: "/")
        guard components.count == 2, components[0] == "Users" else { return false }
        let account = components[1].lowercased()
        return !account.hasPrefix(".") && account != "shared" && account != "deleted users" && account != "localized"
    }

    private static func coverageDescription(_ scan: ScanResult) -> String {
        var notes: [String] = []
        if scan.issueCount > 0 || scan.skippedMounts > 0 || scan.excludedCount > 0 {
            notes.append("The scan had errors, exclusions or volume boundaries. Counts describe observed files only.")
        } else {
            notes.append("Counts cover the regular files measured during the scan.")
        }
        if scan.omittedDirectories > 0 {
            notes.append("The display limit may hide other matching folders. Retained folder totals include their measured descendants.")
        }
        return notes.joined(separator: " ")
    }
}
