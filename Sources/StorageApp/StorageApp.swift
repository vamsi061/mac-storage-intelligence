import AppKit
import SwiftUI

@main
struct StorageIntelligenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = StorageModel()

    var body: some Scene {
        Window("Mac Storage Intelligence", id: "storage") {
            StorageWindow(model: model)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button("Scan Folder…", action: model.chooseFolder)
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
                Button("Cancel Scan", action: model.cancelScan)
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.activeFolder == nil || model.isCancelling)
            }
            CommandMenu("Navigate") {
                ForEach(Array(Destination.allCases.enumerated()), id: \.offset) { index, page in
                    Button(page.title) { model.page = page }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

enum Destination: CaseIterable, Identifiable {
    case dashboard, explorer, largeFiles, applications, cleanup, models, developer, history, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: return "Overview"
        case .explorer: return "Storage explorer"
        case .largeFiles: return "Large files"
        case .applications: return "Applications"
        case .cleanup: return "Cleanup"
        case .models: return "AI models"
        case .developer: return "Developer storage"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "internaldrive"
        case .explorer: return "folder"
        case .largeFiles: return "doc.on.doc"
        case .applications: return "app"
        case .cleanup: return "list.bullet.rectangle"
        case .models: return "brain"
        case .developer: return "hammer"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

private struct StorageWindow: View {
    @ObservedObject var model: StorageModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            List(selection: $model.page) {
                Section("Storage") {
                    Label(Destination.dashboard.title, systemImage: Destination.dashboard.icon)
                        .tag(Destination.dashboard)
                }
                Section("Explore") {
                    ForEach([Destination.explorer, .largeFiles, .applications]) { page in
                        Label(page.title, systemImage: page.icon).tag(page)
                    }
                }
                Section("Manage") {
                    ForEach([Destination.cleanup, .models, .developer]) { page in
                        Label(page.title, systemImage: page.icon).tag(page)
                    }
                }
                Section("Review") {
                    Label(Destination.history.title, systemImage: Destination.history.icon).tag(Destination.history)
                    Label(Destination.settings.title, systemImage: Destination.settings.icon).tag(Destination.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 270)
        } detail: {
            VStack(spacing: 0) {
                if let activity = model.cleanupActivity {
                    ProgressView(activity).controlSize(.small).padding()
                    Divider()
                } else if let folder = model.activeFolder {
                    ScanActivity(model: model, folder: folder)
                    Divider()
                } else if let message = model.scanMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle")
                        Text(message).textSelection(.enabled)
                        Spacer()
                        Button {
                            model.scanMessage = nil
                        } label: {
                            Label("Dismiss message", systemImage: "xmark").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding()
                    Divider()
                }
                switch model.page ?? .dashboard {
                case .dashboard:
                    Dashboard(model: model, showingCoverage: $model.showingCoverage)
                case .explorer:
                    FileBrowser(mode: .browse, model: model)
                case .largeFiles:
                    FileBrowser(mode: .large, model: model)
                case .applications:
                    FileBrowser(mode: .applications, model: model)
                case .models:
                    AIModelsView(model: model)
                case .developer:
                    DeveloperStorageView(model: model)
                case .history:
                    CleanupHistoryView(records: model.history)
                case .settings:
                    SettingsView(model: model)
                case .cleanup:
                    if let result = model.result {
                        CleanupPreview(model: model, result: result)
                            .id(result.root.url)
                    } else {
                        VStack { EmptyScanView(model: model)
                            Button("Choose a File for Trash…", action: model.chooseFileForTrash).disabled(model.isBusy).padding()
                        }
                    }
                }
                if model.result != nil || model.activeFolder != nil {
                    Divider()
                    MonitoringBar(model: model)
                }
            }
            .navigationTitle((model.page ?? .dashboard).title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: model.chooseFolder) {
                        Label("Scan Folder…", systemImage: "folder.badge.plus")
                    }
                    .help("Choose a folder to scan and monitor (⌘O)")
                    .disabled(model.isBusy)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .onAppear { model.startAutomatically() }
        .onChange(of: scenePhase) { phase in
            model.setApplicationActive(phase == .active)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            model.refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            model.refreshVolumes()
        }
        .sheet(item: $model.confirmation) { request in
            ConfirmCleanupView(model: model, request: request)
        }
        .sheet(item: $model.deletionSelection) { request in
            SelectionDeletionView(urls: request.urls) { model.finishSelection($0) }
        }
        .sheet(isPresented: $model.showingCoverage) {
            if let result = model.result {
                CoverageView(result: result, incremental: model.hasIncrementalChanges || model.monitoringError != nil)
            }
        }
        .alert("Finder couldn’t show this item", isPresented: $model.showFinderError) {
            Button("OK") {}
        } message: {
            Text("The item may have moved, or its volume may have disconnected.")
        }
    }
}

private struct ScanActivity: View {
    @ObservedObject var model: StorageModel
    let folder: URL

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(activityTitle)
                    .font(.headline).lineLimit(1)
                if let progress = model.progress, !model.preparingPreview {
                    Text("\(progress.entriesVisited.formatted()) entries visited · \(StorageFormat.size(progress.logicalBytes)) logical")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(progress.filesMeasured.formatted()) files measured · \(StorageFormat.size(progress.allocatedBytes)) allocated · \(progress.issueCount) issues").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: progress.currentPath)
                        .lineLimit(1).truncationMode(.middle).font(.caption).help(progress.currentPath)
                } else {
                    Text(verbatim: folder.path).font(.caption).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Button("Cancel", action: model.cancelScan).disabled(model.isCancelling)
                .help("Cancel scan (⌘.)")
        }
        .padding()
    }

    private var activityTitle: String {
        if model.isCancelling { return "Cancelling scan…" }
        if model.preparingPreview { return "Reviewing measured folders…" }
        return "Scanning \(folder.displayName)"
    }
}

private struct MonitoringBar: View {
    @ObservedObject var model: StorageModel

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(statusText)
            if let verified = model.lastVerifiedAt {
                Text("· Verified \(verified.formatted(date: .omitted, time: .standard))")
            }
            if let updated = model.lastIncrementalAt, model.hasIncrementalChanges {
                Text("· Incremental \(updated.formatted(date: .omitted, time: .standard))")
            }
            if model.monitoringError != nil {
                Label("Directory data may be stale", systemImage: "exclamationmark.triangle")
            } else if model.hasIncrementalChanges {
                Label("Estimated since verification", systemImage: "exclamationmark.triangle")
                    .help("Folder totals were updated from file system events. The next full verification removes estimation drift.")
            }
            if model.pendingChangeCount > 0 {
                Text("· \(model.pendingChangeCount.formatted()) pending")
            }
            if model.isReconciling {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
            }
            Spacer()
            if model.result != nil {
                Button("Coverage") { model.showingCoverage = true }
                    .buttonStyle(.borderless)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .help(model.monitoringError ?? "Volume capacity is read every second. Folder changes update incrementally from FSEvents.")
    }

    private var statusText: String {
        if model.isReconciling { return "Verifying folder totals…" }
        if model.activeFolder != nil { return "Scanning…" }
        return model.monitoringState.label
    }

    private var statusColor: Color {
        if model.isReconciling { return .orange }
        switch model.monitoringState {
        case .active: return .green
        case .starting: return .yellow
        case .idle: return .gray
        case .unavailable: return .red
        }
    }
}

struct EmptyScanView: View {
    @ObservedObject var model: StorageModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder").font(.largeTitle).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.activeFolder == nil ? "Choose a folder to scan" : "Your scan is in progress").font(.title3.bold())
            Text(emptyMessage)
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.activeFolder == nil {
                Button("Scan Folder…", action: model.chooseFolder)
                    .buttonStyle(.borderedProminent).disabled(model.isBusy).padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        if model.activeFolder != nil { return "Results will appear here when the scan finishes." }
        if model.page == .cleanup { return "Choose a folder to check its contents against local cleanup rules." }
        return "On launch the app resumes your last folder, starting with Library/Caches on first use. macOS grants access through the system panel for protected locations."
    }
}
