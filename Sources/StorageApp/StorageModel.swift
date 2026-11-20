import AppKit
import Combine
import Foundation
import StorageCore

@MainActor
final class StorageModel: ObservableObject {
    @Published var page: Destination? = .dashboard
    @Published private(set) var volumes: [StorageVolume] = []
    @Published var selectedVolumeID: URL?
    @Published private(set) var volumeError: String?
    @Published private(set) var refreshingVolumes = false

    @Published private(set) var activeFolder: URL?
    @Published private(set) var choosingFolder = false
    @Published private(set) var isCancelling = false
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var result: ScanResult?
    @Published private(set) var recommendations: [CleanupRecommendation] = []
    @Published private(set) var preparingPreview = false
    @Published private(set) var lastCompletedAt: Date?
    @Published var scanMessage: String?
    @Published var showFinderError = false
    @Published var showingCoverage = false

    @Published var confirmation: CleanupConfirmation?
    @Published private(set) var cleanupActivity: String?
    @Published private(set) var history: [CleanupRecord] = []
    private let historyKey = "storage.cleanupHistory.v1"

    private var volumeRequest = UUID()
    private var scanTask: Task<Void, Never>?
    private static let lastScanKey = "storage.lastCompletedScanDate"

    init() {
        if let data = UserDefaults.standard.data(forKey: historyKey) {
            do { history = try JSONDecoder().decode([CleanupRecord].self, from: data) }
            catch { scanMessage = "Cleanup history could not be read. " + error.localizedDescription }
        }
        lastCompletedAt = UserDefaults.standard.object(forKey: Self.lastScanKey) as? Date
    }

    var isBusy: Bool { choosingFolder || activeFolder != nil || cleanupActivity != nil || confirmation != nil }

    var selectedVolume: StorageVolume? {
        volumes.first { $0.id == selectedVolumeID }
    }

    func refreshVolumes() {
        let request = UUID()
        volumeRequest = request
        refreshingVolumes = true
        Task {
            do {
                let updated = try await Task.detached(priority: .utility) {
                    try VolumeService().mountedVolumes()
                }.value
                guard request == volumeRequest else { return }
                volumes = updated
                if !updated.contains(where: { $0.id == selectedVolumeID }) {
                    selectedVolumeID = updated.first?.id
                }
                volumeError = nil
            } catch {
                guard request == volumeRequest else { return }
                volumes = []
                selectedVolumeID = nil
                volumeError = error.localizedDescription
            }
            refreshingVolumes = false
        }
    }

    func chooseFolder() { chooseFolder(startingAt: nil) }

    func chooseVolumeFolder(_ mount: URL) { chooseFolder(startingAt: mount) }

    private func chooseFolder(startingAt folder: URL?) {
        guard !isBusy else { return }
        choosingFolder = true
        let panel = NSOpenPanel()
        panel.directoryURL = folder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.prompt = "Scan Folder"
        panel.message = "Choose a folder to measure its contents."
        let finished: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.choosingFolder = false
            if response == .OK, let url = panel.url {
                self.scan(folder: url)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finished)
        } else {
            panel.begin(completionHandler: finished)
        }
    }

    private func scan(folder: URL) {
        guard scanTask == nil else { return }
        activeFolder = folder
        progress = nil
        scanMessage = nil
        isCancelling = false
        scanTask = Task {
            defer {
                preparingPreview = false
                activeFolder = nil
                progress = nil
                isCancelling = false
                scanTask = nil
            }

            let (updates, continuation) = AsyncStream<ScanProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let displayUpdates = Task {
                for await update in updates {
                    guard !Task.isCancelled else { break }
                    progress = update
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            defer {
                continuation.finish()
                displayUpdates.cancel()
            }
            do {
                let completed: ScanResult
                do {
                    let scoped = folder.startAccessingSecurityScopedResource()
                    defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                    completed = try await StorageScanner().scan(root: folder) { update in
                        continuation.yield(update)
                    }
                }
                try Task.checkCancellation()
                preparingPreview = true
                let worker = Task.detached(priority: .utility) {
                    let registry = CleanupRuleRegistry()
                    let initial = registry.recommendations(for: completed)
                    let activity = try StorageActivitySnapshot.capture(candidates: initial.map(\.target))
                    return registry.recommendations(for: completed, activity: activity)
                }
                let matches = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                recommendations = matches
                result = completed
                lastCompletedAt = completed.completedAt
                UserDefaults.standard.set(completed.completedAt, forKey: Self.lastScanKey)
                refreshVolumes()
            } catch {
                if Task.isCancelled || error is CancellationError {
                    scanMessage = "Cancelled the scan of \(folder.path)."
                } else {
                    let cause = error as NSError
                    let permissionCodes = [Int(POSIXErrorCode.EACCES.rawValue), Int(POSIXErrorCode.EPERM.rawValue)]
                    let guidance = cause.domain == NSPOSIXErrorDomain && permissionCodes.contains(cause.code)
                        ? " Review file access in System Settings under Privacy & Security, or choose another folder."
                        : ""
                    scanMessage = error.localizedDescription + guidance
                }
            }
        }
    }

    func chooseFileForTrash() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.prompt = "Review File"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Choose a file directly in Downloads or Desktop, or a log under Library/Logs. You’ll review the file before moving it to Trash."
        choosingFolder = true
        panel.begin { response in
            self.choosingFolder = false
            if response == .OK, let url = panel.url { self.reviewTrash(url) }
        }
    }

    func reviewTrash(_ url: URL) {
        prepareCleanup(action: "Move to Trash", target: url) {
            let ticket = try TrashExecutor.prepare(url)
            return CleanupConfirmation(action: "Move to Trash", target: ticket.url,
                explanation: "Move this file (\(StorageFormat.size(ticket.logicalBytes))) to Trash? You can restore it in Finder. Space may remain occupied until Trash is emptied.",
                operation: .trash(ticket))
        }
    }

    func reviewPackage(_ match: CleanupRecommendation) {
        prepareCleanup(action: "Clean Package Cache", target: match.target) {
            let ticket = try PackageCleanup.prepare(match)
            return CleanupConfirmation(action: "Clean Package Cache", target: match.target,
                explanation: ticket.summary + "\n\n" + match.consequences, operation: .package(ticket))
        }
    }

    private func prepareCleanup(action: String, target: URL,
                                prepare: @escaping @Sendable () throws -> CleanupConfirmation) {
        guard !isBusy else { return }
        cleanupActivity = "Checking the selected item…"
        Task {
            defer { cleanupActivity = nil }
            do { confirmation = try await Task.detached(priority: .userInitiated, operation: prepare).value }
            catch {
                record(CleanupRecord(id: UUID(), date: Date(), action: action, path: target.path,
                                     status: "Blocked", detail: error.localizedDescription))
                scanMessage = error.localizedDescription
                page = .history
            }
        }
    }

    func confirmCleanup(_ request: CleanupConfirmation) {
        guard confirmation?.id == request.id, cleanupActivity == nil, activeFolder == nil else { return }
        confirmation = nil
        cleanupActivity = request.action + "…"
        let folder = result?.root.url
        var entry = CleanupRecord(id: request.id, date: Date(), action: request.action, path: request.target.path,
                                  status: "Started", detail: "Final outcome has not been recorded.")
        record(entry)
        Task {
            do {
                entry.detail = try await Task.detached(priority: .userInitiated) {
                    switch request.operation {
                    case .trash(let ticket): return try TrashExecutor.execute(ticket)
                    case .package(let ticket): return try PackageCleanup.execute(ticket)
                    }
                }.value
                entry.status = "Completed"
            } catch {
                entry.status = "Failed"
                entry.detail = error.localizedDescription
            }
            record(entry)
            cleanupActivity = nil
            page = .history
            refreshVolumes()
            if let folder {
                result = nil
                recommendations = []
                scan(folder: folder)
            }
        }
    }

    private func record(_ entry: CleanupRecord) {
        history.removeAll { $0.id == entry.id }
        history.insert(entry, at: 0)
        do { UserDefaults.standard.set(try JSONEncoder().encode(history), forKey: historyKey) }
        catch { scanMessage = "Could not save the cleanup history. " + error.localizedDescription }
    }

    func cancelScan() {
        guard scanTask != nil else { return }
        isCancelling = true
        scanTask?.cancel()
    }

    func reveal(_ item: URL) {
        showFinderError = !NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
    }

    func openContainingFolder(of item: URL) {
        showFinderError = !NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.deletingLastPathComponent().path)
    }
}

extension URL {
    var displayName: String {
        lastPathComponent.isEmpty ? path : lastPathComponent
    }
}

enum StorageFormat {
    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "Unavailable" }
        if bytes == 0 { return "0 bytes" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}
