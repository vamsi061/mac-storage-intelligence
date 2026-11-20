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
        .defaultSize(width: 1040, height: 690)
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
    case dashboard, folders, files, cleanup, history

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: return "Overview"
        case .folders: return "Folder tree"
        case .files: return "Largest files"
        case .cleanup: return "Cleanup"
        case .history: return "Cleanup history"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "internaldrive"
        case .folders: return "folder"
        case .files: return "doc.on.doc"
        case .cleanup: return "list.bullet.rectangle"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

private struct StorageWindow: View {
    @ObservedObject var model: StorageModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.page) {
                Section("Storage") {
                    Label(Destination.dashboard.title, systemImage: Destination.dashboard.icon)
                        .tag(Destination.dashboard)
                }
                Section("Explorer") {
                    ForEach([Destination.folders, .files]) { page in
                        Label(page.title, systemImage: page.icon).tag(page)
                    }
                }
                Section("Review") {
                    Label(Destination.cleanup.title, systemImage: Destination.cleanup.icon)
                        .tag(Destination.cleanup)
                    Label(Destination.history.title, systemImage: Destination.history.icon).tag(Destination.history)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
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
                case .folders, .files:
                    if let result = model.result {
                        Explorer(model: model, result: result, showingCoverage: $model.showingCoverage)
                            .id(result.completedAt)
                    } else {
                        EmptyScanView(model: model)
                    }
                case .history:
                    CleanupHistoryView(records: model.history)
                case .cleanup:
                    if let result = model.result {
                        CleanupPreview(model: model, result: result)
                            .id(result.completedAt)
                    } else {
                        VStack { EmptyScanView(model: model)
                            Button("Choose a File for Trash…", action: model.chooseFileForTrash).disabled(model.isBusy).padding()
                        }
                    }
                }
            }
            .navigationTitle((model.page ?? .dashboard).title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: model.chooseFolder) {
                        Label("Scan Folder…", systemImage: "folder.badge.plus")
                    }
                    .help("Choose a folder to scan (⌘O)")
                    .disabled(model.isBusy)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 470)
        .onAppear { model.refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            model.refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            model.refreshVolumes()
        }
        .sheet(item: $model.confirmation) { request in
            ConfirmCleanupView(model: model, request: request)
        }
        .sheet(isPresented: $model.showingCoverage) {
            if let result = model.result {
                CoverageView(result: result)
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
        if model.page == .cleanup { return "Scan a folder to check its measured contents against local cleanup rules." }
        return "See folder sizes and the largest files inside."
    }
}
