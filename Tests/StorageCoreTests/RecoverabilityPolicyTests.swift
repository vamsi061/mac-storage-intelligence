import Foundation
#if !STORAGE_FIXTURE_RUNNER
@testable import StorageCore
import XCTest
#endif

enum RecoverabilityChecks {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
        if !condition() { throw Failure(reason) }
    }

    private static func recommendation(_ id: String, _ risk: CleanupRisk) -> CleanupRecommendation {
        CleanupRecommendation(
            id: id, title: "Fixture " + id,
            target: URL(fileURLWithPath: "/fixture/" + id, isDirectory: true),
            logicalBytes: 1_024, allocatedBytes: 512, fileCount: 1, risk: risk,
            reason: "Measured fixture", consequences: "Fixture consequences",
            regeneration: "Fixture regeneration", applicationGuidance: "Finish work",
            nextAction: "Review", coverageNote: "Observed files only",
            inUseStatus: "Unknown"
        )
    }

    private static func verifiedPolicy() -> RecoverabilityPolicy {
        RecoverabilityPolicy(capabilities: .init { match in
            match.id == "npm.content-cache"
                ? OfficialCleanup(mechanism: "Injected official npm cleanup", restoration: "Run npm install again.")
                : nil
        })
    }

    static func run() throws {
        let policy = RecoverabilityPolicy(capabilities: .init { _ in nil })
        let verified = verifiedPolicy()

        let cache = recommendation("npm.content-cache", .regenerableCache)
        let verifiedAssessment = verified.assess(cache)
        try require(verifiedAssessment.classification == .verifiedRecoverable,
                    "An installed official mechanism did not classify as verified")
        try require(verifiedAssessment.isDeletable && verifiedAssessment.deletionAllowed,
                    "Verified resource was not deletable")
        try require(verifiedAssessment.allowedModes == [.permanent],
                    "Verified resource must use permanent supported cleanup")
        try require(!verifiedAssessment.requiresHighRiskConfirmation,
                    "Verified cleanup incorrectly required a typed confirmation")
        try require(verifiedAssessment.evidence.contains("Injected official"), "Verified evidence missing")

        let noMechanism = policy.assess(cache)
        try require(noMechanism.classification == .unknownRecoverability,
                    "Cache was treated as recoverable without an installed mechanism")
        try require(!noMechanism.isDeletable && noMechanism.allowedModes.isEmpty,
                    "Unknown app-managed cache was deletable through generic filesystem deletion")

        let protectedCache = policy.assess(recommendation("npm.content-cache", .protected))
        try require(protectedCache.classification == .protected && !protectedCache.isDeletable,
                    "Protected recommendation was deletable")
        let modelStore = policy.assess(recommendation("ollama.models", .highRiskData))
        try require(modelStore.classification == .protected && !modelStore.isDeletable,
                    "Managed model store was not protected")

        let log = policy.assess(recommendation("user.log-file:/fixture/old.log", .reviewRecommended))
        try require(log.classification == .unknownRecoverability && log.isDeletable,
                    "Explicit ordinary log was not eligible for advanced deletion")
        try require(log.allowedModes == [.trash, .permanent] && log.requiresHighRiskConfirmation,
                    "Unknown ordinary file did not require high-risk confirmation or both modes")
        try require(log.confirmationPhrase == "DELETE", "Wrong typed confirmation phrase")
        try require(log.confirmationPhrase != "delete" && log.confirmationPhrase != "", "Phrase comparison is not exact")

        let home = FileManager.default.homeDirectoryForCurrentUser
        let userFile = policy.assessUserItem(at: home.appendingPathComponent("Documents/notes.txt"))
        try require(userFile.classification == .unknownRecoverability && userFile.isDeletable,
                    "Ordinary user file was not advanced-deletable")
        try require(userFile.requiresHighRiskConfirmation && userFile.requiresHighRiskConfirmation,
                    "Ordinary user file lacked high-risk confirmation")

        let application = policy.assessUserItem(at: URL(fileURLWithPath: "/Applications/Example.app"))
        try require(application.classification == .partiallyRecoverable && application.isDeletable,
                    "Application bundle was not partially recoverable")
        try require(application.requiresHighRiskConfirmation && application.allowedModes.contains(.trash),
                    "Application bundle did not require high-risk Trash confirmation")
        try require(application.restoration.lowercased().contains("reinstall"), "Application restoration missing")

        for path in ["/", "/System/Library/CoreServices", "/Library/Preferences", "/private/etc"] {
            let assessment = policy.assessUserItem(at: URL(fileURLWithPath: path))
            try require(assessment.classification == .protected && !assessment.isDeletable,
                        "System path was not protected: " + path)
        }

        let model = policy.assessManagedModel(identifier: "llama3:8b", restoration: "Run ollama pull llama3:8b.")
        try require(model.classification == .partiallyRecoverable && model.isDeletable,
                    "Managed model was not partially recoverable")
        try require(model.allowedModes == [.permanent] && model.requiresHighRiskConfirmation,
                    "Managed model did not require permanent high-risk confirmation")

        let volume = DockerResource(kind: .volume, identifier: "data", name: "data", detail: "local",
                                    bytes: nil, canRemove: false)
        try require(policy.assessDocker(volume).classification == .protected,
                    "Docker volume was not protected")
        let container = DockerResource(kind: .container, identifier: String(repeating: "a", count: 64),
                                       name: "web", detail: "exited", bytes: nil, canRemove: true)
        let containerAssessment = policy.assessDocker(container)
        try require(containerAssessment.classification == .partiallyRecoverable && containerAssessment.isDeletable,
                    "Stopped container was not partially recoverable")
        let image = DockerResource(kind: .image, identifier: "sha256:" + String(repeating: "b", count: 64),
                                   name: "Untagged image", detail: "untagged", bytes: 10, canRemove: true)
        try require(policy.assessDocker(image).classification == .unknownRecoverability,
                    "Untagged image was treated as verified recoverable")

        let rows = [
            DeletionOutcomeRow(status: "Completed", logicalBytes: 2_048,
                               detail: "Moved to Trash. Observed source-volume available-space change: -2048 bytes."),
            DeletionOutcomeRow(status: "Failed", logicalBytes: 1_024, detail: "Permission denied."),
            DeletionOutcomeRow(status: "Cancelled", logicalBytes: 512, detail: "Skipped.")
        ]
        let summary = DeletionOutcomeReporter.summarize(rows)
        try require(summary.contains("1 of 3 operations completed"), "Wrong success count")
        try require(summary.contains("2 failed or cancelled"), "Wrong failure count")
        try require(summary.contains("-2048 bytes"), "Observed space change was not reported")
        try require(DeletionOutcomeReporter.observedChange(in: rows[0].detail) == -2_048,
                    "Observed change parser failed")
        try require(DeletionOutcomeReporter.observedChange(in: "No measurement") == nil,
                    "Missing measurement was invented")
    }
}

#if !STORAGE_FIXTURE_RUNNER
final class RecoverabilityPolicyTests: XCTestCase {
    func testClassificationConfirmationAndReporting() throws { try RecoverabilityChecks.run() }
}
#endif
