import AppKit
import QuickLookUI
import StorageCore
import SwiftUI

@MainActor
private final class BrowserState: ObservableObject {
    @Published var rows: [InventoryItem] = []
    @Published var selection = Set<URL>()
    @Published var search = ""
    @Published var kind = "All types"
    @Published var order = "Name"
    @Published var includeHidden = false
    @Published var message = ""
    @Published var inspected: InventoryItem?
    @Published var eventRevision = 0
    @Published var folderMode = "Browse"
    @Published var directoryRanking = false
    @Published var measuring = false

    func binding<T>(_ keyPath: ReferenceWritableKeyPath<BrowserState, T>) -> Binding<T> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}

struct FileBrowser: View {
    enum Mode { case browse, large, applications }
    let mode: Mode
    @ObservedObject var model: StorageModel
    @StateObject private var state = BrowserState()

    private var location: URL { model.browserLocation }
    private var token: String {
        [location.path, String(model.inventoryRevision), String(model.lastIncrementalAt?.timeIntervalSince1970 ?? 0),
         String(model.result?.completedAt.timeIntervalSince1970 ?? 0), String(state.eventRevision), String(state.directoryRanking)].joined(separator: "|")
    }
    private var visible: [InventoryItem] {
        state.rows.filter { item in
            (state.includeHidden || !item.hidden) && (state.kind == "All types" || item.kind == state.kind) &&
                (state.search.isEmpty || item.url.path.localizedCaseInsensitiveContains(state.search))
        }.sorted { lhs, rhs in
            if state.order == "Size", lhs.logical != rhs.logical { return (lhs.logical ?? -1) > (rhs.logical ?? -1) }
            if state.order == "Type", lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            if state.order == "Modified", lhs.modified != rhs.modified { return (lhs.modified ?? .distantPast) > (rhs.modified ?? .distantPast) }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if mode == .browse {
                HStack {
                    Picker("View", selection: state.binding(\.folderMode)) {
                        Text("Browse").tag("Browse")
                        Text("Monitored tree and treemap").tag("Tree")
                    }.pickerStyle(.segmented)
                    Menu("Locations") {
                        Button("Home") { navigate(FileManager.default.homeDirectoryForCurrentUser) }
                        if let root = model.result?.root.url { Button("Monitored folder") { navigate(root) } }
                        Divider()
                        ForEach(model.volumes) { volume in Button(volume.name + " · " + volume.id.path) { navigate(volume.id) } }
                    }.fixedSize()
                }.padding(.horizontal)
            }
            if mode == .browse && state.folderMode == "Tree" {
                if let result = model.result { Explorer(model: model, result: result, showingCoverage: $model.showingCoverage) }
                else { EmptyScanView(model: model) }
            } else {
                if mode == .browse { breadcrumbs }
                if mode == .large {
                    Picker("Largest", selection: state.binding(\.directoryRanking)) {
                        Text("Files").tag(false)
                        Text("Directories").tag(true)
                    }.pickerStyle(.segmented).padding(.horizontal)
                }
                HStack {
                    TextField(mode == .browse ? "Search this folder" : "Search listed paths", text: state.binding(\.search))
                        .textFieldStyle(.roundedBorder)
                    Picker("Type", selection: state.binding(\.kind)) {
                        Text("All types").tag("All types")
                        ForEach(Set(state.rows.map(\.kind)).sorted(), id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: 180)
                    Picker("Sort", selection: state.binding(\.order)) {
                        ForEach(["Name", "Size", "Type", "Modified"], id: \.self) { Text($0).tag($0) }
                    }.fixedSize()
                    Toggle("Hidden", isOn: state.binding(\.includeHidden))
                }.padding(.horizontal)
                if !state.message.isEmpty { Text(state.message).font(.callout).foregroundStyle(.secondary).padding(.horizontal) }
                if state.measuring {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Measuring folder sizes on disk…")
                        Spacer()
                    }.font(.callout).foregroundStyle(.secondary).padding(.horizontal)
                }
                List(visible, selection: state.binding(\.selection)) { item in
                    HStack {
                        Image(systemName: item.link ? "link" : item.directory ? (mode == .applications ? "app" : "folder") : "doc")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(verbatim: item.url.lastPathComponent)
                            if mode != .browse { Text(verbatim: item.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary) }
                        }.lineLimit(1)
                        Spacer()
                        Text(item.kind).foregroundStyle(.secondary).font(.caption)
                        Text(item.logical.map { StorageFormat.size($0) } ?? (item.directory ? "Size unavailable" : "Unmeasured"))
                            .monospacedDigit().frame(minWidth: 82, alignment: .trailing)
                            .help(item.logical == nil && item.directory ? "The folder could not be measured. Review permissions or Coverage." : "")
                    }.tag(item.url).contextMenu {
                        Button("Inspect…") { state.inspected = item }
                        Button("Reveal in Finder") { model.reveal(item.url) }
                        Button("Delete…") { model.reviewSelection([item.url]) }
                    }
                }
                .contextMenu(forSelectionType: URL.self) { urls in
                    Button("Delete Selected…") { model.reviewSelection(Array(urls)) }.disabled(urls.isEmpty)
                } primaryAction: { urls in
                    if urls.count == 1, let item = state.rows.first(where: { urls.contains($0.url) }) { open(item) }
                }
                HStack {
                    Text("\(visible.count) listed · \(state.selection.count) selected").font(.caption)
                    Spacer()
                    if let item = selectedItem {
                        if item.directory && mode != .applications { Button("Browse") { open(item) } }
                        Button("Inspect…") { state.inspected = item }
                        Button("Reveal") { model.reveal(item.url) }
                    }
                    Button(state.selection.count > 1 ? "Delete Selected…" : "Delete…") { model.reviewSelection(Array(state.selection)) }
                        .disabled(state.selection.isEmpty)
                }.padding(.horizontal)
            }
        }
        .padding(.vertical, 10)
        .onAppear { state.order = mode == .large ? "Size" : "Name" }
        .onChange(of: state.search) { _ in state.selection.removeAll() }
        .onChange(of: state.kind) { _ in state.selection.removeAll() }
        .onChange(of: state.includeHidden) { _ in state.selection.removeAll() }
        .task(id: token) { await load() }
        .task(id: location) {
            guard mode == .browse else { return }
            let folder = location
            let (stream, writer) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let monitor = FileSystemEventMonitor(root: folder) { events in
                if events.contains(where: { $0.requiresFullRescan || URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == folder.path }) { writer.yield(()) }
            }
            defer { monitor.stop(); writer.finish() }
            do { try monitor.start() } catch { return }
            for await _ in stream {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 800_000_000)
                if !Task.isCancelled { state.eventRevision &+= 1 }
            }
        }
        .sheet(item: state.binding(\.inspected)) { item in FileInspection(item: item, model: model) }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(Array(location.pathComponents.indices), id: \.self) { index in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption) }
                    Button(location.pathComponents[index]) {
                        navigate(URL(fileURLWithPath: NSString.path(withComponents: Array(location.pathComponents.prefix(index + 1))), isDirectory: true))
                    }.buttonStyle(.borderless)
                }
            }.padding(.horizontal)
        }
    }
    private var selectedItem: InventoryItem? { state.selection.count == 1 ? state.rows.first { state.selection.contains($0.url) } : nil }
    private func navigate(_ url: URL) {
        state.selection.removeAll(); state.rows = []; state.search = ""; state.kind = "All types"; state.folderMode = "Browse"
        model.browserLocation = url
    }
    private func open(_ item: InventoryItem) {
        if item.directory && !item.link && item.kind != "Application" {
            navigate(item.url); model.page = .explorer
        } else { state.inspected = item }
    }

    @MainActor private func load() async {
        let scans = model.inventoryResults
        let root = location
        let mode = mode
        let automaticRoot = model.activeFolder
        let folders = state.directoryRanking
        state.measuring = true
        defer { state.measuring = false }
        let worker = Task.detached(priority: .utility) { () async throws -> ([InventoryItem], String) in
            var rows: [InventoryItem] = []
            var seen = Set<String>()
            func measured(_ url: URL) -> DirectoryNode? {
                for scan in scans {
                    guard let path = InventoryPaths.alias(of: url, under: scan.root.url),
                          let node = scan.deepestDirectory(containing: path), node.url.path == path else { continue }
                    return node
                }
                return nil
            }
            var note = ""
            switch mode {
            case .browse:
                var folder = measured(root)
                let children = Dictionary(uniqueKeysWithValues: (folder?.children ?? []).map {
                    (root.appendingPathComponent($0.url.lastPathComponent, isDirectory: true), $0)
                })
                var listing = try DirectoryListing.read(root, measurements: children)
                let missingSizes = listing.items.contains { $0.directory && !$0.link && $0.logical == nil }
                let coveredByAutomatic = automaticRoot.map {
                    root.path == $0.path || root.path.hasPrefix($0.path == "/" ? "/" : $0.path + "/")
                } ?? false
                if folder == nil, coveredByAutomatic {
                    // Never launch a second full traversal of the folder the automatic scan is
                    // already measuring. The completed result updates this view through its token.
                    rows = []
                    note = "The automatic scan is measuring this location. Folder sizes will appear when it finishes."
                } else if folder == nil || missingSizes || (folder?.children.isEmpty == true && listing.items.contains(where: \.directory)) {
                    // The selected folder is outside a retained scan branch or beyond its display
                    // limit. Measure its immediate children once so no folder remains permanently
                    // unmeasured. This does not replace the whole-system inventory scope.
                    let measuredFolder = try await FullScanQueue.shared.scan(
                        root,
                        options: ScanOptions(largestFileLimit: 0, directoryLimit: 1,
                                             issueLimit: 25, minimumRetainedDepth: 1))
                    try Task.checkCancellation()
                    folder = measuredFolder.root
                    let measuredChildren = Dictionary(uniqueKeysWithValues: measuredFolder.root.children.map {
                        (root.appendingPathComponent($0.url.lastPathComponent, isDirectory: true), $0)
                    })
                    listing = try DirectoryListing.read(root, measurements: measuredChildren)
                    note = "Folder sizes were measured on demand without replacing the monitored inventory scope."
                    if measuredFolder.issueCount > 0 {
                        note += " \(measuredFolder.issueCount) entries could not be read because of permissions or filesystem errors."
                    }
                }
                rows = listing.items
                if listing.unreadable > 0 { note += (note.isEmpty ? "" : " ") + "\(listing.unreadable) entries could not be inspected." }
            case .large:
                for scan in scans {
                    try Task.checkCancellation()
                    if folders {
                        var pending = scan.root.children
                        var biggest: [DirectoryNode] = []
                        while let node = pending.popLast() {
                            pending.append(contentsOf: node.children)
                            biggest.append(node)
                        }
                        for node in biggest.sorted(by: { $0.logicalBytes > $1.logicalBytes }).prefix(150) {
                            if let item = try? InventoryItem(node.url, measurement: node), seen.insert(item.identity).inserted { rows.append(item) }
                        }
                    } else {
                        for file in scan.largestFiles {
                            if let item = try? InventoryItem(file.url), seen.insert(item.identity).inserted { rows.append(item) }
                        }
                    }
                }
                note = "Ranked from completed scans. Parent directory sizes include their descendants."
            case .applications:
                let manager = FileManager.default
                var locations = Set(manager.urls(for: .applicationDirectory, in: .allDomainsMask))
                locations.insert(manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true))
                var apps = Set<URL>()
                var failures = 0
                for location in locations where manager.fileExists(atPath: location.path) {
                    guard let listing = manager.enumerator(at: location, includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsPackageDescendants], errorHandler: { _, _ in failures += 1; return true }) else { failures += 1; continue }
                    for case let url as URL in listing {
                        try Task.checkCancellation()
                        if url.pathExtension.lowercased() == "app" { apps.insert(url); listing.skipDescendants() }
                    }
                }
                for scan in scans {
                    var pending = [scan.root]
                    while let node = pending.popLast() {
                        if node.url.pathExtension.lowercased() == "app" { apps.insert(node.url) }
                        else { pending.append(contentsOf: node.children) }
                    }
                }
                for url in apps {
                    if let item = try? InventoryItem(url, measurement: measured(url)), !item.link, seen.insert(item.identity).inserted { rows.append(item) }
                }
                note = "Bundle sizes exclude associated user data. Inspect an app to locate matching support folders."
                if failures > 0 { note += " \(failures) locations could not be read." }
            }
            return (rows, note)
        }
        do {
            let (items, note) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            state.rows = items; state.message = note
            state.selection.formIntersection(Set(visible.map(\.url)))
        } catch {
            if !Task.isCancelled { state.rows = []; state.selection = []; state.message = "Could not read \(root.path). " + error.localizedDescription }
        }
    }
}

private struct FileInspection: View {
    let item: InventoryItem
    @ObservedObject var model: StorageModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = InspectionState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(item.url.lastPathComponent).font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }
            Text(verbatim: item.url.path).textSelection(.enabled)
            Text("\(item.kind) · Modified \(item.modified?.formatted() ?? "unknown")")
            Text("Logical size: \(StorageFormat.size(item.logical)) · Allocated estimate: \(StorageFormat.size(item.allocated))")
            Text("Recovery is uncertain. APFS snapshots and clones can retain shared blocks. A Trash move usually releases no space immediately.").font(.callout).foregroundStyle(.secondary)
            if item.kind == "Application" {
                Text("Associated storage").font(.headline)
                if state.associations.isEmpty { Text("No accessible exact bundle-identifier matches measured. Other associated data may exist.") }
                ForEach(state.associations) { associated in
                    Button(associated.url.path + " · " + StorageFormat.size(associated.logical)) { model.reveal(associated.url) }
                }
            }
            if !item.directory && !item.link {
                if state.preview { QuickPreview(url: item.url).frame(minHeight: 220) }
                else { Button("Quick Look") { state.preview = true } }
            }
            Button("Reveal in Finder") { model.reveal(item.url) }
        }.padding(22).frame(minWidth: 520, maxWidth: 640)
        .task {
            guard item.kind == "Application", let identifier = Bundle(url: item.url)?.bundleIdentifier,
                  !identifier.contains("/"), identifier != ".." else { return }
            let scans = model.inventoryResults
            let found = await Task.detached(priority: .utility) {
                let home = FileManager.default.homeDirectoryForCurrentUser
                return ["Library/Application Support", "Library/Caches", "Library/Containers"].compactMap { base in
                    let url = home.appendingPathComponent(base).appendingPathComponent(identifier, isDirectory: true)
                    let node = scans.compactMap { $0.deepestDirectory(containing: url.path) }.first { $0.url.path == url.path }
                    return try? InventoryItem(url, measurement: node)
                }
            }.value
            state.associations = found
        }
    }
}

@MainActor
private final class InspectionState: ObservableObject {
    @Published var preview = false
    @Published var associations: [InventoryItem] = []
}

private struct QuickPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .normal)! }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}
