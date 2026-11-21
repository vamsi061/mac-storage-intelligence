import StorageCore
import SwiftUI

struct CleanupPreview: View {
    @ObservedObject var model: StorageModel
    let result: ScanResult
    @StateObject private var selection = CleanupSelection()

    private var selectable: [CleanupRecommendation] {
        model.allRecommendations.filter { BulkCleanupAction.forMatch($0) != .none }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: result.root.url.path).font(.headline).textSelection(.enabled)
                HStack {
                    Text("Scanned \(result.completedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose a File for Trash…", action: model.chooseFileForTrash).disabled(model.isBusy)
                    Button("View coverage") { model.showingCoverage = true }
                }
            }
            .padding()
            Divider()
            if model.allRecommendations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No matching locations").font(.title3.bold())
                    Text("The rules check standard cache, build and model locations in your home folder. This scan found no matching locations with measured files.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if result.issueCount > 0 || result.omittedDirectories > 0 {
                        Text("Some entries could not be read or displayed. Review scan coverage for details.")
                            .font(.callout).multilineTextAlignment(.center)
                    }
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Locations to review (\(model.allRecommendations.count.formatted()))")
                                .font(.title2.bold())
                            Spacer()
                            Button("Select all eligible") { selection.select(selectable) }
                                .disabled(selectable.isEmpty)
                            Button("Clear") { selection.selected.removeAll() }
                                .disabled(selection.selected.isEmpty)
                        }
                        Text("Sizes come from the latest folder measurements. Select checkboxes for individual or bulk actions. APFS clones and snapshots can keep blocks in use, so actual recovery can be lower.")
                            .foregroundStyle(.secondary)
                        ForEach(model.allRecommendations, id: \.id) { match in
                            Divider()
                            RecommendationRow(model: model, match: match, selection: selection)
                        }
                        CleanupBulkBar(model: model, recommendations: model.allRecommendations, selection: selection)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct RecommendationRow: View {
    @ObservedObject var model: StorageModel
    let match: CleanupRecommendation
    @ObservedObject var selection: CleanupSelection

    private var assessment: RecoverabilityAssessment { RecoverabilityPolicy().assess(match) }
    private var action: BulkCleanupAction { BulkCleanupAction.forMatch(match) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                if action != .none {
                    Button {
                        selection.toggle(match.id)
                    } label: {
                        Image(systemName: selection.selected.contains(match.id) ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.borderless)
                    .help(selection.selected.contains(match.id) ? "Deselect for bulk action" : "Select for bulk action")
                }
                Text(verbatim: match.title).font(.headline)
                Spacer()
                Text("\(StorageFormat.size(match.logicalBytes)) logical").monospacedDigit()
            }
            Text(verbatim: match.target.path).font(.callout).textSelection(.enabled)
            Label(assessment.classification.label, systemImage: assessment.classification.allowsDeletion ? "checkmark.shield" : "lock.shield")
                .font(.callout.bold())
            Text(verbatim: assessment.classification.summary).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: match.reason)
            Text(verbatim: assessment.evidence).font(.caption).foregroundStyle(.secondary)
            detail("Estimated recovery", match.recoveryEstimate)
            if match.risk == .protected { detail("Protection", match.inUseStatus) }
            if assessment.classification == .verifiedRecoverable, assessment.isDeletable {
                Button("Clean with installed tool…") { model.reviewPackage(match) }.disabled(model.isBusy)
            } else if assessment.isDeletable,
                      match.id.hasPrefix("user.log-file:") || match.id.hasPrefix("user.temp-file:"),
                      TrashExecutor.isEligibleLocation(match.target) {
                Button("Advanced deletion…") { model.reviewSelection([match.target]) }.disabled(model.isBusy)
            } else if assessment.deletionAllowed == false {
                Label("Deletion disabled", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Review details") {
                VStack(alignment: .leading, spacing: 10) {
                    detail("Measured", "\(match.fileCount.formatted()) files, \(StorageFormat.size(match.allocatedBytes)) allocated estimate")
                    detail("Detection confidence", match.confidence)
                    detail("Coverage", match.coverageNote)
                    detail("Consequences", match.consequences)
                    detail("Regeneration", match.regeneration)
                    detail("Restoration", assessment.restoration)
                    detail("Deletion method", assessment.methodSummary.isEmpty ? "None available" : assessment.methodSummary)
                    detail("High-risk confirmation", assessment.requiresHighRiskConfirmation ? "Required (type DELETE)" : "Standard confirmation")
                    detail("Current use", match.inUseStatus)
                    detail("Applications", match.applicationGuidance)
                    detail("Next action", match.nextAction)
                    Button("Show in Finder") { model.reveal(match.target) }
                }
                .padding(.top, 7).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: value).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private final class CleanupSelection: ObservableObject {
    @Published var selected = Set<String>()

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func select(_ matches: [CleanupRecommendation]) {
        selected = Set(matches.map(\.id))
    }
}

private enum BulkCleanupAction: Equatable {
    case none, verified, advanced

    static func forMatch(_ match: CleanupRecommendation) -> Self {
        let assessment = RecoverabilityPolicy().assess(match)
        guard assessment.isDeletable else { return .none }
        if assessment.classification == .verifiedRecoverable, PackageCleanup.supports(match) {
            return .verified
        }
        if (match.id.hasPrefix("user.log-file:") || match.id.hasPrefix("user.temp-file:")),
           TrashExecutor.isEligibleLocation(match.target) {
            return .advanced
        }
        return .none
    }
}

private struct CleanupBulkBar: View {
    @ObservedObject var model: StorageModel
    let recommendations: [CleanupRecommendation]
    @ObservedObject var selection: CleanupSelection

    private var selected: [CleanupRecommendation] {
        recommendations.filter { selection.selected.contains($0.id) }
    }
    private var verified: [CleanupRecommendation] {
        selected.filter { BulkCleanupAction.forMatch($0) == .verified }
    }
    private var advanced: [CleanupRecommendation] {
        selected.filter { BulkCleanupAction.forMatch($0) == .advanced }
    }
    private var bytes: Int64 {
        selected.reduce(Int64(0)) { $0 + max(0, $1.allocatedBytes) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if selected.isEmpty {
                Text("Select one or more eligible locations for bulk actions. Protected locations remain disabled.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selected.count.formatted()) selected · \(StorageFormat.size(bytes)) estimated")
                        .font(.callout.weight(.semibold))
                    Text("Individual actions remain available above. Bulk actions use the same recoverability policy and confirmations.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !verified.isEmpty {
                Button("Clean \(verified.count) selected cache(s)…") { model.reviewPackages(verified) }
                    .disabled(model.isBusy)
            }
            if !advanced.isEmpty {
                Button("Review \(advanced.count) selected file(s)…") {
                    model.reviewSelection(advanced.map(\.target))
                }
                .disabled(model.isBusy)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
