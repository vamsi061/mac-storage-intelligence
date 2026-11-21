import AppKit
import StorageCore
import SwiftUI

@MainActor
private final class SettingsState: ObservableObject {
    @Published var message: String?

    func binding<T>(_ keyPath: ReferenceWritableKeyPath<SettingsState, T>) -> Binding<T> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}

struct SettingsView: View {
    @ObservedObject var model: StorageModel
    @StateObject private var state = SettingsState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GroupBox("Monitoring") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Monitor all mounted volumes", isOn: Binding(
                            get: { model.monitorAll },
                            set: { model.setMonitorAll($0) }))
                        Text("Off by default so launch never triggers privacy prompts. When enabled, each local volume gets an inventory scan; macOS may ask for access to removable volumes or protected folders once. Protected home locations are excluded automatically.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        LabeledContent("Shown volume") {
                            Text(model.selectedVolume?.name ?? "Unavailable")
                        }
                        LabeledContent("Last full verification") {
                            Text(model.lastVerifiedAt?.formatted(date: .abbreviated, time: .standard) ?? "Not yet")
                        }
                        LabeledContent("Monitoring") {
                            Text(model.monitoringState.label)
                        }
                        if let error = model.monitoringError {
                            Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Volumes") {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.volumes.isEmpty {
                            Text("No mounted volumes are available.").foregroundStyle(.secondary)
                        }
                        ForEach(model.volumes) { volume in
                            Toggle(isOn: Binding(
                                get: { !model.disabledMounts.contains(volume.id.path) },
                                set: { model.setVolume(volume.id, enabled: $0) })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: volume.name)
                                    Text(verbatim: volume.id.path).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!volume.automaticallyInventoried)
                            if !volume.automaticallyInventoried {
                                Text("Network, virtual and system-managed volumes are not inventoried automatically.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Excluded folders") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Excluded folders are never scanned or monitored. Use this for private or slow locations.")
                            .font(.callout).foregroundStyle(.secondary)
                        if model.excludedFolders.isEmpty {
                            Text("No custom exclusions.").foregroundStyle(.secondary)
                        }
                        ForEach(model.excludedFolders, id: \.self) { path in
                            HStack {
                                Text(verbatim: path).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Remove") {
                                    model.updateExclusions(model.excludedFolders.filter { $0 != path })
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("Add Folder…") { addExclusion() }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Permissions") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The app never bypasses macOS privacy controls. Access to Desktop, Documents, Downloads and similar locations is granted only when you select or add a folder, or after you grant Full Disk Access.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Open Privacy & Security Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            Button("Open Folder Access Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        Text("Full Disk Access lets the scanner measure protected folders without repeated prompts. Only grant it if you want the app to inventory the whole disk.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Safety") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Deletion always requires confirmation. Ordinary files default to Trash; permanent deletion must be selected explicitly. Protected system resources, managed model stores and active files are refused.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Selections are revalidated immediately before deletion using file identity checks and descriptor-relative operations.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message = state.message {
                    Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Exclude"
        panel.message = "Choose a folder that should never be scanned or monitored."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !model.excludedFolders.contains(url.path) else { return }
        model.updateExclusions(model.excludedFolders + [url.path])
    }
}
