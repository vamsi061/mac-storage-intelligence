import StorageCore
import SwiftUI

struct Explorer: View {
    @ObservedObject var model: StorageModel
    let result: ScanResult
    @Binding var showingCoverage: Bool
    @StateObject private var controls = ExplorerControls()

    private var isFolderView: Bool { model.page == .explorer }
    private var selection: URL? { isFolderView ? (controls.showMap ? nil : controls.selectedFolder) : controls.selectedFile }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: result.root.url.path)
                    .font(.headline).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                HStack {
                    Text("Scanned \(result.completedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button(result.issueCount > 0 ? "Coverage (\(result.issueCount.formatted()) issues)" : "View coverage") {
                        showingCoverage = true
                    }
                }
            }
            .padding()
            Divider()
            if isFolderView {
                Picker("Folder view", selection: $controls.showMap) {
                    Text("Tree").tag(false)
                    Text("Treemap").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 6)
                if controls.showMap {
                    FolderMap(root: result.root)
                } else {
                    folderTree
                }
            } else {
                fileTable
            }
            Divider()
            HStack(spacing: 8) {
                if let selection {
                    Text(verbatim: selection.path)
                        .lineLimit(1).truncationMode(.middle).help(selection.path)
                } else {
                    Text(isFolderView ? "Sizes include files in each folder’s subtree." : "\(visibleFiles.count.formatted()) of \(result.largestFiles.count.formatted()) listed files")
                }
                Spacer()
                if !isFolderView, let selection, TrashExecutor.isEligibleLocation(selection) {
                    Button("Move to Trash…") { model.reviewTrash(selection) }.disabled(model.isBusy)
                }
                if isFolderView, let selection {
                    Button("Review deletion…") { model.reviewSelection([selection]) }.disabled(model.isBusy)
                }
                Button("Show in Finder") {
                    if let selection { model.reveal(selection) }
                }
                .disabled(selection == nil)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal).padding(.vertical, 9)
        }
    }

    private var folderTree: some View {
        List(selection: $controls.selectedFolder) {
            DisclosureGroup(isExpanded: $controls.rootExpanded) {
                OutlineGroup(result.root.children, children: \.outlineChildren) { node in
                    folderRow(node)
                }
            } label: {
                folderRow(result.root)
            }
            .tag(result.root.url)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .accessibilityLabel("Folder tree, logical sizes")
    }

    private func folderRow(_ node: DirectoryNode) -> some View {
        HStack {
            Label {
                Text(verbatim: node.url.displayName).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: "folder").foregroundStyle(.tint)
            }
            Spacer()
            if node.unreadableEntryCount > 0 {
                Label("Partial", systemImage: "exclamationmark.triangle").font(.caption)
                    .help("Some entries in this folder could not be measured. See Coverage for paths and errors.")
            }
            Text("\(node.fileCount.formatted()) files").font(.caption).foregroundStyle(.secondary)
            Text(StorageFormat.size(node.logicalBytes))
                .monospacedDigit().frame(minWidth: 85, alignment: .trailing)
        }
        .tag(node.url)
        .help(node.url.path)
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Show in Finder") { model.reveal(node.url) }
            Button("Open Containing Folder") { model.openContainingFolder(of: node.url) }
            Button("Review deletion…") { model.reviewSelection([node.url]) }
        }
    }

    @ViewBuilder private var fileTable: some View {
        HStack(spacing: 14) {
            TextField("Filter listed files by name or path", text: $controls.search)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Filter largest files")
                .onChange(of: controls.search) { _ in controls.selectedFile = nil }
            Picker("Sort", selection: $controls.fileOrder) {
                ForEach(FileOrder.allCases, id: \.self) { order in Text(order.rawValue).tag(order) }
            }
            .fixedSize()
        }
        .padding(.horizontal).padding(.vertical, 9)
        if visibleFiles.isEmpty {
            Text(result.largestFiles.isEmpty ? "No regular files were measured in this folder." : "No listed files match this filter.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(visibleFiles, selection: $controls.selectedFile) {
                TableColumn("File") { file in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: file.url.displayName)
                        Text(file.storageKind.rawValue).font(.caption2).foregroundStyle(.secondary)
                        Text(verbatim: file.url.deletingLastPathComponent().path)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .lineLimit(1).truncationMode(.middle).help(file.url.path)
                }
                .width(min: 140, ideal: 260)
                TableColumn("Logical size") { file in
                    Text(StorageFormat.size(file.logicalBytes)).monospacedDigit()
                }
                .width(min: 76, ideal: 95)
                TableColumn("Allocated est.") { file in
                    Text(StorageFormat.size(file.allocatedBytes)).monospacedDigit()
                }
                .width(min: 85, ideal: 100)
                TableColumn("Modified") { file in
                    Text(file.modifiedAt?.formatted(date: .abbreviated, time: .omitted) ?? "Unavailable")
                }
                .width(min: 88, ideal: 110)
            }
            .contextMenu(forSelectionType: URL.self) { items in
                if let item = items.first {
                    Button("Show in Finder") { model.reveal(item) }
                    Button("Open Containing Folder") { model.openContainingFolder(of: item) }
                }
            }
            .accessibilityLabel("Largest files")
        }
    }

    private var visibleFiles: [ScannedFile] {
        let filtered = controls.search.isEmpty ? result.largestFiles : result.largestFiles.filter {
            $0.url.path.localizedCaseInsensitiveContains(controls.search)
        }
        switch controls.fileOrder {
        case .size:
            return filtered
        case .name:
            return filtered.sorted { $0.url.displayName.localizedStandardCompare($1.url.displayName) == .orderedAscending }
        case .modified:
            return filtered.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        }
    }
}

private extension DirectoryNode {
    var outlineChildren: [DirectoryNode]? { children.isEmpty ? nil : children }
}

private enum FileOrder: String, CaseIterable {
    case size = "Largest first"
    case name = "Name"
    case modified = "Newest first"
}

@MainActor
private final class ExplorerControls: ObservableObject {
    @Published var selectedFolder: URL?
    @Published var selectedFile: URL?
    @Published var showMap = false
    @Published var rootExpanded = true
    @Published var search = ""
    @Published var fileOrder = FileOrder.size
}

struct CoverageView: View {
    let result: ScanResult
    var incremental = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Scan coverage").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: result.root.url.path).font(.headline).textSelection(.enabled)
                    Text(incremental ? "Incremental estimates since the last verification." : "Full traversal completed " + result.completedAt.formatted() + ".")
                        .foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                        count("Files measured", result.root.fileCount)
                        count("Scan issues", result.issueCount)
                        count("Symbolic links skipped", result.skippedLinks)
                        count("Mount boundaries skipped", result.skippedMounts)
                        count("Duplicate entries skipped", result.skippedDuplicates)
                        count("Excluded entries", result.excludedCount)
                        count("Folders omitted from the tree", result.omittedDirectories)
                    }
                    Text("Logical size counts file lengths. Allocated estimates can include blocks shared by APFS clones. Snapshots and system storage also affect volume usage.")
                        .foregroundStyle(.secondary)
                    if result.omittedDirectories > 0 {
                        Text("The tree reached its display limit. Folder totals still include files measured beyond that limit.")
                    }
                    Divider()
                    if result.issueCount == 0 {
                        Label("The scanner reported no access or filesystem errors.", systemImage: "checkmark.circle")
                    } else {
                        Text("Access and filesystem errors").font(.headline)
                        Text("Entries that macOS could not read may be missing from totals. You can review the app’s file access in System Settings under Privacy & Security.")
                            .foregroundStyle(.secondary)
                        Text("Showing \(result.issues.count.formatted()) of \(result.issueCount.formatted()) issues.")
                        ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: issue.url.path).font(.callout.weight(.medium))
                                Text(verbatim: issue.message).font(.caption).foregroundStyle(.secondary)
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .frame(width: 530, height: 470)
    }

    private func count(_ label: String, _ value: Int) -> some View {
        GridRow {
            Text(label)
            Text(value.formatted()).monospacedDigit().gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
