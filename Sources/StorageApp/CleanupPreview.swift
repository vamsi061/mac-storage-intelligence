import StorageCore
import SwiftUI

struct CleanupPreview: View {
    @ObservedObject var model: StorageModel
    let result: ScanResult

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
                        Text("Locations to review (\(model.allRecommendations.count.formatted()))")
                            .font(.title2.bold())
                        Text("Sizes come from the latest folder measurements. APFS clones and snapshots can keep blocks in use, so recovery can be zero.")
                            .foregroundStyle(.secondary)
                        ForEach(model.allRecommendations, id: \.id) { match in
                            Divider()
                            RecommendationRow(model: model, match: match)
                        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: match.title).font(.headline)
                Spacer()
                Text("\(StorageFormat.size(match.logicalBytes)) logical").monospacedDigit()
            }
            Text(verbatim: match.target.path).font(.callout).textSelection(.enabled)
            Label(match.risk.label, systemImage: "info.circle").font(.callout)
            Text(verbatim: match.reason)
            detail("Estimated recovery", match.recoveryEstimate)
            if match.risk == .protected { detail("Protection", match.inUseStatus) }
            if PackageCleanup.supports(match) {
                Button("Review Cache Cleanup…") { model.reviewPackage(match) }.disabled(model.isBusy)
            } else if (match.id.hasPrefix("user.log-file:") || match.id.hasPrefix("user.temp-file:")),
                      match.risk != .protected, TrashExecutor.isEligibleLocation(match.target) {
                Button("Move to Trash…") { model.reviewTrash(match.target) }.disabled(model.isBusy)
            }
            DisclosureGroup("Review details") {
                VStack(alignment: .leading, spacing: 10) {
                    detail("Measured", "\(match.fileCount.formatted()) files, \(StorageFormat.size(match.allocatedBytes)) allocated estimate")
                    detail("Detection confidence", match.confidence)
                    detail("Coverage", match.coverageNote)
                    detail("Consequences", match.consequences)
                    detail("Regeneration", match.regeneration)
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
