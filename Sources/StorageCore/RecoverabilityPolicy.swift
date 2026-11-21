import Foundation

/// The only deletion classes the application recognises. A resource is never promoted to a
/// recoverable class based on its name, extension, or the mere existence of a vendor website.
public enum RecoverabilityClass: String, Sendable, CaseIterable, Hashable {
    case verifiedRecoverable = "Verified recoverable"
    case partiallyRecoverable = "Partially recoverable"
    case unknownRecoverability = "Unknown recoverability"
    case protected = "Protected"

    public var label: String { rawValue }

    public var summary: String {
        switch self {
        case .verifiedRecoverable:
            return "Removal can be reversed with a verified, installed mechanism."
        case .partiallyRecoverable:
            return "The software can be restored, but some local data or state may not be."
        case .unknownRecoverability:
            return "No restoration mechanism could be verified."
        case .protected:
            return "System-critical, shared, active, or otherwise unsafe to delete."
        }
    }

    public var allowsDeletion: Bool { self != .protected }
}

/// Evidence of a real, installed cleanup interface. A UI label alone must never create one.
public struct OfficialCleanup: Sendable, Equatable {
    public let mechanism: String
    public let restoration: String
    public init(mechanism: String, restoration: String) {
        self.mechanism = mechanism
        self.restoration = restoration
    }
}

/// A deletion decision produced by verified capabilities, not by guessing from a filename.
public struct RecoverabilityAssessment: Sendable, Equatable {
    public let classification: RecoverabilityClass
    public let evidence: String
    public let consequences: String
    public let restoration: String
    public let deletionAllowed: Bool
    public let requiresHighRiskConfirmation: Bool
    public let allowedModes: [SelectionDeletionMode]

    public var isDeletable: Bool { deletionAllowed && !allowedModes.isEmpty }
    public var confirmationPhrase: String? { requiresHighRiskConfirmation ? "DELETE" : nil }
    public var methodSummary: String { allowedModes.map(\.rawValue).joined(separator: " or ") }
}

public struct RecoverabilityPolicy: Sendable {
    /// Injected so tests can prove that a verified class requires a real mechanism.
    public struct Capabilities: Sendable {
        public var officialCleanup: @Sendable (CleanupRecommendation) -> OfficialCleanup?
        public init(officialCleanup: @escaping @Sendable (CleanupRecommendation) -> OfficialCleanup?) {
            self.officialCleanup = officialCleanup
        }

        public static let live = Capabilities { match in
            guard PackageCleanup.supports(match) else { return nil }
            if match.id == "pip.cache" {
                return OfficialCleanup(
                    mechanism: "pip cache remove through Apple’s Command Line Tools interpreter, sandboxed to the reviewed wheel files.",
                    restoration: "Re-run pip install. Wheels can be downloaded again or rebuilt from source while the package index and build tools remain available."
                )
            }
            guard let tool = DeveloperCacheTool.allCases.first(where: { $0.rule == match.id }) else { return nil }
            let restoration: String
            switch tool {
            case .npm: restoration = "Run npm install; published packages repopulate the cache from the registry."
            case .pnpm: restoration = "Run pnpm install; the store repopulates from the registry."
            case .yarn: restoration = "Run yarn install; the cache repopulates from the registry."
            case .uv: restoration = "Run uv sync or uv pip install; environments and wheels are rebuilt or downloaded again."
            case .brew: restoration = "Run brew install or brew upgrade; bottles and source archives are downloaded again."
            }
            return OfficialCleanup(
                mechanism: "The installed \(tool.rawValue) executable runs its own cleanup command, network-disabled, with writes restricted to this cache.",
                restoration: restoration
            )
        }
    }

    public let capabilities: Capabilities

    public init(capabilities: Capabilities = .live) {
        self.capabilities = capabilities
    }

    // MARK: - Cleanup recommendations

    public func assess(_ match: CleanupRecommendation) -> RecoverabilityAssessment {
        if match.risk == .protected || match.risk == .highRiskData {
            return RecoverabilityAssessment(
                classification: .protected,
                evidence: "The scan classified this location as protected or application-managed data. " + match.reason,
                consequences: match.consequences,
                restoration: match.regeneration,
                deletionAllowed: false,
                requiresHighRiskConfirmation: false,
                allowedModes: []
            )
        }

        // Verified only when an installed interface was found at assessment time.
        if let cleanup = capabilities.officialCleanup(match) {
            return RecoverabilityAssessment(
                classification: .verifiedRecoverable,
                evidence: cleanup.mechanism,
                consequences: match.consequences,
                restoration: cleanup.restoration + " " + match.regeneration,
                deletionAllowed: true,
                requiresHighRiskConfirmation: false,
                allowedModes: [.permanent]
            )
        }

        if match.id.hasPrefix("user.log-file:") || match.id.hasPrefix("user.temp-file:") {
            return RecoverabilityAssessment(
                classification: .unknownRecoverability,
                evidence: "You explicitly selected an ordinary file the scan measured. No re-download or regeneration source can be verified.",
                consequences: match.consequences,
                restoration: "Restore it from Trash if it was moved. Permanent deletion requires a separate, independently verified backup.",
                deletionAllowed: true,
                requiresHighRiskConfirmation: true,
                allowedModes: [.trash, .permanent]
            )
        }

        if match.id == "xcode.derived-data" {
            return RecoverabilityAssessment(
                classification: .partiallyRecoverable,
                evidence: "Xcode rebuilds products and indexes, but build logs, test results, and archived products stored here may be unique.",
                consequences: match.consequences,
                restoration: "Reopen the projects and rebuild. Preserve logs, test results, and any unique products before cleaning.",
                deletionAllowed: false,
                requiresHighRiskConfirmation: false,
                allowedModes: []
            )
        }

        return RecoverabilityAssessment(
            classification: .unknownRecoverability,
            evidence: "No installed official cleanup interface was verified for this location. The application that owns this data may regenerate it, but that cannot be proven here.",
            consequences: match.consequences,
            restoration: match.regeneration,
            deletionAllowed: false,
            requiresHighRiskConfirmation: false,
            allowedModes: []
        )
    }

    // MARK: - User-selected items

    public func assessUserItem(at url: URL) -> RecoverabilityAssessment {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let systemRoots = ["/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/private", "/var", "/dev", "/cores"]

        if path == "/" || systemRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return protectedAssessment(reason: "The path is owned by macOS or the system volume and is not an ordinary user file.")
        }
        if path == "/Applications" {
            return protectedAssessment(reason: "The Applications folder itself cannot be deleted.")
        }

        let isApplication = url.pathExtension.lowercased() == "app"
        if isApplication && url.deletingLastPathComponent().standardizedFileURL.path == "/Applications" {
            return RecoverabilityAssessment(
                classification: .partiallyRecoverable,
                evidence: "An installed application bundle can usually be reinstalled, but its installer source, version, license state, and local configuration cannot be verified.",
                consequences: "The application bundle is removed. Support files, preferences, containers, and documents outside the bundle are not deleted by this action and may be orphaned.",
                restoration: "Reinstall from the Mac App Store, the vendor’s download, or an independent backup. Associated data is not restored by reinstalling.",
                deletionAllowed: true,
                requiresHighRiskConfirmation: true,
                allowedModes: [.trash, .permanent]
            )
        }

        if path.hasPrefix(home + "/") || path.hasPrefix("/Volumes/") {
            return RecoverabilityAssessment(
                classification: .unknownRecoverability,
                evidence: "You explicitly selected this item. No re-download, regeneration, or reinstallation mechanism can be verified for its contents.",
                consequences: "The selected files may be unique. Moving to Trash keeps them recoverable until Trash is emptied; permanent deletion cannot be undone without an independent backup.",
                restoration: "Restore from Trash if the item was moved there. Permanent deletion requires a separate backup because the app cannot recover the contents.",
                deletionAllowed: true,
                requiresHighRiskConfirmation: true,
                allowedModes: [.trash, .permanent]
            )
        }

        return protectedAssessment(reason: "The item is outside your home folder, /Applications, or a local external volume.")
    }

    // MARK: - Managed resources

    public func assessManagedModel(identifier: String, restoration: String) -> RecoverabilityAssessment {
        RecoverabilityAssessment(
            classification: .partiallyRecoverable,
            evidence: "A supported management interface is available for \(identifier), but registry availability, private revisions, and locally created weights cannot be verified.",
            consequences: "The model is removed from local storage. Shared blobs may remain, so the displayed logical size may not be recovered. Inference using this model stops until it is restored.",
            restoration: restoration + " Published revisions can be downloaded again only while their source remains available. Shared layers may delay space reclamation.",
            deletionAllowed: true,
            requiresHighRiskConfirmation: true,
            allowedModes: [.permanent]
        )
    }

    public func assessDocker(_ resource: DockerResource) -> RecoverabilityAssessment {
        if resource.kind == .volume {
            return protectedAssessment(reason: "Docker volumes are persistent application data and can contain the only copy of databases or uploads. Remove them only through an explicit, reviewed Docker workflow.")
        }
        guard resource.canRemove else {
            return protectedAssessment(reason: "The resource is running, attached, or otherwise active. Stop and review it in Docker before removal.")
        }
        switch resource.kind {
        case .container:
            return RecoverabilityAssessment(
                classification: .partiallyRecoverable,
                evidence: "A stopped container can be recreated from its image, but its writable layer and any state not stored in a volume are unique.",
                consequences: resource.consequence,
                restoration: "Recreate the container from the recorded image. Mounted volumes are retained; writable-layer changes are not recoverable.",
                deletionAllowed: true,
                requiresHighRiskConfirmation: true,
                allowedModes: [.permanent]
            )
        case .image:
            return RecoverabilityAssessment(
                classification: .unknownRecoverability,
                evidence: "Only untagged images are removable here. An untagged image has no verified upstream reference, so a re-pull cannot be guaranteed.",
                consequences: resource.consequence,
                restoration: "Re-pull the image only if its original repository and digest are known. Shared layers can remain allocated.",
                deletionAllowed: true,
                requiresHighRiskConfirmation: true,
                allowedModes: [.permanent]
            )
        case .volume:
            return protectedAssessment(reason: "Docker volumes are persistent data.")
        }
    }

    private func protectedAssessment(reason: String) -> RecoverabilityAssessment {
        RecoverabilityAssessment(
            classification: .protected,
            evidence: reason,
            consequences: "Deletion is disabled so macOS, applications, shared data, and active resources stay intact.",
            restoration: "No deletion is performed. Use the owning application or macOS settings for supported maintenance.",
            deletionAllowed: false,
            requiresHighRiskConfirmation: false,
            allowedModes: []
        )
    }
}

public struct DeletionOutcomeRow: Sendable, Equatable {
    public let status: String
    public let logicalBytes: Int64
    public let detail: String
    public init(status: String, logicalBytes: Int64, detail: String) {
        self.status = status
        self.logicalBytes = logicalBytes
        self.detail = detail
    }
}

public enum DeletionOutcomeReporter {
    /// Summarises mixed success. The observed free-space change is parsed only from reports that
    /// measured it; it is never substituted with the logical size.
    public static func summarize(_ rows: [DeletionOutcomeRow]) -> String {
        let completed = rows.filter { $0.status == "Completed" }.count
        let failed = rows.filter { $0.status == "Failed" || $0.status == "Cancelled" }.count
        let blocked = rows.filter { $0.status == "Blocked" }.count
        let estimated = rows.reduce(Int64(0)) { total, row in
            let (sum, overflow) = total.addingReportingOverflow(max(0, row.logicalBytes))
            return overflow ? Int64.max : sum
        }
        let changes = rows.compactMap { observedChange(in: $0.detail) }
        let observed = changes.reduce(Int64(0), +)
        let size = ByteCountFormatter.string(fromByteCount: estimated, countStyle: .file)
        var parts = ["\(completed) of \(rows.count) operations completed"]
        if failed > 0 { parts.append("\(failed) failed or cancelled") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        parts.append("estimated reclaimable \(size)")
        if changes.isEmpty {
            parts.append("actual available-space change was not measured")
        } else {
            let actual = ByteCountFormatter.string(fromByteCount: observed, countStyle: .file)
            parts.append("observed available-space change \(observed >= 0 ? "+" : "")\(actual) (\(observed) bytes); other disk activity can affect this")
        }
        return parts.joined(separator: " · ") + "."
    }

    static func observedChange(in detail: String) -> Int64? {
        let pattern = #"(?i)(?:change|delta)[^0-9-]*(-?\d+)\s*bytes"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)),
              match.numberOfRanges == 2,
              let range = Range(match.range(at: 1), in: detail) else { return nil }
        return Int64(detail[range])
    }
}
