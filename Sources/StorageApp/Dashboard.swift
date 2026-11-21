import StorageCore
import SwiftUI

struct Dashboard: View {
    @ObservedObject var model: StorageModel
    @Binding var showingCoverage: Bool

    private var breakdown: StorageBreakdown { model.storageBreakdown }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                capacitySection
                Divider()
                measuredScopeSection
                Divider()
                discoveredSection
                if let record = model.history.first {
                    Divider()
                    recentCleanup(record)
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Capacity and recoverable storage

    private var capacitySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Storage overview").font(.title2.bold())
                Spacer()
                if !model.volumes.isEmpty {
                    Picker("Volume", selection: $model.selectedVolumeID) {
                        ForEach(model.volumes) { volume in
                            Text(verbatim: volumeTitle(volume)).tag(Optional(volume.id))
                        }
                    }
                    .labelsHidden().frame(maxWidth: 250)
                    .accessibilityLabel("Volume for capacity reporting")
                }
            }
            if let volume = model.selectedVolume {
                HStack(spacing: 12) {
                    Image(systemName: volume.isRemovable ? "externaldrive.fill" : "internaldrive.fill")
                        .font(.system(size: 34)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: volume.name).font(.title3.weight(.semibold))
                        Text(verbatim: volume.id.path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer()
                    if volume.isReadOnly { Label("Read-only", systemImage: "lock").font(.caption) }
                }

                recoverableHero

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 178), spacing: 18)],
                          alignment: .leading, spacing: 16) {
                    Metric(title: "Total disk capacity", value: StorageFormat.size(breakdown.totalBytes))
                    Metric(title: "Available storage", value: StorageFormat.size(breakdown.availableBytes))
                    Metric(title: "Occupied storage", value: StorageFormat.size(breakdown.usedBytes))
                    Metric(title: "System-managed & shared", value: StorageFormat.size(breakdown.sharedBytes))
                    Metric(title: "Measured user data", value: StorageFormat.size(breakdown.measuredUserBytes))
                    Metric(title: "Potentially recoverable", value: StorageFormat.size(breakdown.recoverableBytes))
                    Metric(title: "Unknown or inaccessible", value: StorageFormat.size(breakdown.unmeasuredBytes))
                }

                if breakdown.totalBytes > 0 {
                    CapacityChart(total: breakdown.totalBytes, used: breakdown.usedBytes,
                                  available: breakdown.availableBytes)
                    Text("Shared/reserved storage is reported separately and is not added to occupied storage a second time. Measured values are observations within the scanned roots; APFS snapshots and shared blocks can keep space allocated after files are removed.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.volumeError { Text(error).foregroundStyle(.secondary) }
                HStack {
                    Button("Scan this volume…") { model.chooseVolumeFolder(volume.id) }
                        .disabled(model.isBusy)
                    if model.applicationsLoading {
                        ProgressView("Discovering applications…").controlSize(.small)
                    }
                }
            } else if model.refreshingVolumes {
                ProgressView("Reading mounted volumes…").controlSize(.small)
            } else {
                Text(model.volumeError ?? "No mounted volumes are available.").foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var recoverableHero: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Potentially Recoverable Storage", systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Text(StorageFormat.size(breakdown.recoverableBytes))
                    .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("\(breakdown.recoverableItems.formatted()) eligible cleanup item(s), counted only from measured, currently deletable candidates. Actual recovery can be lower because of shared blocks, snapshots and tool behavior.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Review cleanup") { model.page = .cleanup }
                .buttonStyle(.borderedProminent)
                .disabled(model.allRecommendations.isEmpty)
        }
        .padding(20)
        .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.green.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Scan progress and measured scope

    private var measuredScopeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Measured storage").font(.title2.bold())
                Spacer()
                if model.result != nil {
                    Button("View coverage") { showingCoverage = true }
                }
            }
            if let folder = model.activeFolder {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text("Scanning \(folder.path)").font(.headline).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Cancel", action: model.cancelScan).disabled(model.isCancelling)
                    }
                    if let progress = model.progress {
                        Text("\(progress.entriesVisited.formatted()) entries · \(progress.filesMeasured.formatted()) files · \(StorageFormat.size(progress.logicalBytes)) logical · \(StorageFormat.size(progress.allocatedBytes)) allocated")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Text(verbatim: progress.currentPath)
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                        if progress.issueCount > 0 {
                            Label("\(progress.issueCount.formatted()) inaccessible or unreadable entries so far. Those bytes are not counted.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                        }
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            if let result = model.result {
                HStack(alignment: .top, spacing: 20) {
                    Metric(title: "Measured accessible", value: StorageFormat.size(breakdown.measuredAccessibleBytes))
                    Metric(title: "Measured user home", value: StorageFormat.size(breakdown.measuredUserBytes))
                    Metric(title: "Outside measured scope", value: StorageFormat.size(breakdown.unmeasuredBytes))
                }
                Text("\(breakdown.measuredRootCount.formatted()) non-overlapping measured root(s). Root paths that contain one another are counted once. Unknown/inaccessible storage is occupied space not attributed to a measured root, including protected data, other APFS volumes, snapshots and filesystem metadata.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                    Text(verbatim: result.root.url.path)
                        .font(.headline).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                }
                Text(result.completedAt.formatted(date: .abbreviated, time: .standard) + " · last full verification · \(model.monitoringState.label)")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let error = model.monitoringError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                }
                if model.hasIncrementalChanges {
                    Label("Folder totals include incremental updates. They are estimates until the next full verification.",
                          systemImage: "clock.arrow.2.circlepath")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 20) {
                    Metric(title: "Logical size", value: StorageFormat.size(result.root.logicalBytes))
                    Metric(title: "Allocated estimate", value: StorageFormat.size(result.root.allocatedBytes))
                    Metric(title: "Files counted", value: result.root.fileCount.formatted())
                }
                if result.issueCount > 0 {
                    HStack(alignment: .firstTextBaseline) {
                        Label("\(result.issueCount.formatted()) entries could not be read. Measured sizes exclude them; this is a permission limitation, not zero usage.", systemImage: "lock.trianglebadge.exclamationmark")
                            .font(.callout)
                        Button("Review coverage") { showingCoverage = true }.buttonStyle(.borderless)
                    }
                } else {
                    Label("No unreadable entries were reported in this scan.", systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !result.root.children.isEmpty {
                    Text("Largest measured subfolders").font(.headline)
                    ForEach(result.root.children.prefix(6)) { child in
                        HStack {
                            Text(verbatim: child.url.displayName).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(StorageFormat.size(child.allocatedBytes)).monospacedDigit()
                            Text("allocated").font(.caption2).foregroundStyle(.secondary)
                        }
                        .help(child.url.path + " — " + StorageFormat.size(child.logicalBytes) + " logical")
                    }
                }
                HStack {
                    Button("Browse folders") { model.page = .explorer }
                    Button("View largest files") { model.page = .largeFiles }
                    if !model.recoverableCandidates.isEmpty {
                        Button("Review cleanup (\(model.recoverableCandidates.count.formatted()))") { model.page = .cleanup }
                    }
                }
                PermissionChrome(model: model)
            } else if model.activeFolder == nil {
                if let date = model.lastCompletedAt {
                    Text("Last completed \(date.formatted(date: .abbreviated, time: .standard)). Start a new scan to browse measured results.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("The app automatically measures your home folder and installed applications. Choose another folder only if you want a different scope.")
                        .foregroundStyle(.secondary)
                }
                Button("Scan Folder…", action: model.chooseFolder)
                    .buttonStyle(.borderedProminent).disabled(model.isBusy)
            }
        }
    }

    // MARK: - Automatically discovered resources

    private var discoveredSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Discovered in measured locations").font(.title2.bold())
            Text("Applications are discovered separately from the home scan. AI models, downloads and caches are read from measured home folders; large files come from the retained ranking.")
                .font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)],
                      alignment: .leading, spacing: 14) {
                DiscoveryCard(icon: "app", title: "Applications",
                              value: StorageFormat.size(model.applicationBundles.reduce(Int64(0)) { $0 + $1.allocatedBytes }),
                              detail: "\(model.applicationBundles.count.formatted()) bundles measured") {
                    model.page = .applications
                }
                DiscoveryCard(icon: "brain", title: "AI models",
                              value: StorageFormat.size(model.aiModelBytes),
                              detail: "Ollama, Hugging Face and local inference stores") {
                    model.page = .models
                }
                DiscoveryCard(icon: "arrow.down.circle", title: "Downloads",
                              value: StorageFormat.size(model.homeDownloadsBytes),
                              detail: "Measured ~/Downloads") {
                    model.browserLocation = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Downloads", isDirectory: true)
                    model.page = .explorer
                }
                DiscoveryCard(icon: "archivebox", title: "Caches",
                              value: StorageFormat.size(model.homeCachesBytes),
                              detail: "Measured ~/Library/Caches") {
                    model.page = .cleanup
                }
                DiscoveryCard(icon: "doc.on.doc", title: "Large files",
                              value: "\(model.result?.largestFiles.count ?? 0) listed",
                              detail: "Ranked from this scan; open for paths and sizes") {
                    model.page = .largeFiles
                }
                DiscoveryCard(icon: "wand.and.stars", title: "Cleanup candidates",
                              value: StorageFormat.size(model.potentialRecoverableBytes),
                              detail: "\(model.recoverableCandidates.count.formatted()) eligible items") {
                    model.page = .cleanup
                }
            }
            if let error = model.applicationsError {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func recentCleanup(_ record: CleanupRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Most recent cleanup").font(.title2.bold())
            HStack {
                Text(record.action).font(.headline)
                Spacer()
                Text(record.status).font(.subheadline.bold())
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: record.detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Button("View history") { model.page = .history }
        }
    }

    private func volumeTitle(_ volume: StorageVolume) -> String {
        let sharesName = model.volumes.contains { $0.id != volume.id && $0.name == volume.name }
        return sharesName ? "\(volume.name) (\(volume.id.path))" : volume.name
    }
}

private struct PermissionChrome: View {
    @ObservedObject var model: StorageModel

    var body: some View {
        HStack {
            Text(model.excludedFolders.isEmpty ? "No custom exclusions." :
                    "\(model.excludedFolders.count.formatted()) excluded folder(s). Excluded bytes are never counted.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Permissions & exclusions") { model.page = .settings }
                .buttonStyle(.borderless)
        }
    }
}

private struct DiscoveryCard: View {
    let icon: String
    let title: String
    let value: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: icon).font(.headline)
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private enum CapacityPart: String, CaseIterable {
    case used = "Occupied"
    case shared = "System-managed or shared"
    case free = "Available"

    var color: Color {
        switch self {
        case .used: return .accentColor
        case .shared: return .orange
        case .free: return .green
        }
    }
}

@MainActor private final class ChartSelection: ObservableObject {
    @Published var part = CapacityPart.used
}

private struct CapacityChart: View {
    let total: Int64
    let used: Int64
    let available: Int64
    @StateObject private var selection = ChartSelection()

    private func bytes(_ part: CapacityPart) -> Int64 {
        switch part {
        case .used: return used
        case .shared: return max(0, total - available - used)
        case .free: return available
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(CapacityPart.allCases, id: \.self) { part in
                        Button { selection.part = part } label: {
                            Rectangle().fill(part.color)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(part.rawValue)
                        .accessibilityValue(StorageFormat.size(bytes(part)))
                        .frame(width: geometry.size.width * CGFloat(Double(bytes(part)) / Double(max(1, total))))
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 4))
            }.frame(height: 18)
            Picker("Storage distribution", selection: $selection.part) {
                ForEach(CapacityPart.allCases, id: \.self) { part in Text(part.rawValue).tag(part) }
            }.pickerStyle(.segmented).labelsHidden()
            Text("\(selection.part.rawValue) · \(StorageFormat.size(bytes(selection.part))) · \((Double(bytes(selection.part)) / Double(max(1, total))).formatted(.percent.precision(.fractionLength(1))))")
                .font(.callout).monospacedDigit()
        }
    }
}
