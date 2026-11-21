import StorageCore
import SwiftUI

private enum AIModelSelection: Identifiable {
    case ollama(OllamaModel), hub(HuggingFaceModel)
    var id: String {
        switch self {
        case .ollama(let model): return model.name
        case .hub(let repo): return repo.identifier
        }
    }
    var location: String {
        switch self {
        case .ollama: return "Local Ollama service · 127.0.0.1:11434"
        case .hub(let repo): return repo.url.path
        }
    }
}

@MainActor
private final class AIModelsState: ObservableObject {
    @Published var tags: [OllamaModel] = []
    @Published var repositories: [HuggingFaceModel] = []
    @Published var inferenceFiles: [ScannedFile] = []
    @Published var apiError: String?
    @Published var cacheError: String?
    @Published var refreshing = false
    @Published var deleting = false
    @Published var selection: AIModelSelection?
    @Published var typed = ""
    @Published var outcome: String?
    @Published var lastRefresh: Date?

    func binding<T>(_ keyPath: ReferenceWritableKeyPath<AIModelsState, T>) -> Binding<T> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}

struct AIModelsView: View {
    @ObservedObject var model: StorageModel
    private let ollama = OllamaService()
    private let hub = HuggingFaceCache()
    @StateObject private var state = AIModelsState()

    private var files: [ScannedFile] {
        var unique = [String: ScannedFile]()
        for file in model.inventoryResults.flatMap(\.largestFiles) + state.inferenceFiles
        where AIModelFiles.isWeight(file.url) && !AIModelFiles.isManaged(file.url, cache: hub.root) {
            unique[file.url.path] = file
        }
        return unique.values.sorted {
            $0.logicalBytes == $1.logicalBytes ? $0.url.path < $1.url.path : $0.logicalBytes > $1.logicalBytes
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let lastRefresh = state.lastRefresh {
                    Text("Updated \(lastRefresh.formatted(date: .abbreviated, time: .standard))").foregroundStyle(.secondary)
                }
                Spacer()
                if state.refreshing || state.deleting { ProgressView().controlSize(.small) }
                Button("Refresh models") { Task { await refresh() } }.disabled(state.refreshing || state.deleting)
            }.padding(.horizontal).padding(.top)
            if let outcome = state.outcome { Text(verbatim: outcome).textSelection(.enabled).padding(.horizontal) }
            List {
                Section("Ollama") {
                    if let apiError = state.apiError { Text(verbatim: apiError).foregroundStyle(.secondary) }
                    else if state.tags.isEmpty { Text(state.refreshing ? "Checking local service…" : "No installed models reported.").foregroundStyle(.secondary) }
                    ForEach(state.tags) { tag in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(verbatim: tag.name).font(.headline).textSelection(.enabled)
                                Spacer()
                                Button("Review deletion…") { review(.ollama(tag)) }
                                    .disabled(tag.running != false || state.deleting || state.refreshing)
                            }
                            Text("\(StorageFormat.size(tag.bytes)) reported · \(tag.running.map { $0 ? "Running" : "Idle" } ?? "Running status unknown")")
                            if let shared = tag.sharedBytes, let exclusive = tag.exclusiveBytes {
                                Text("\(StorageFormat.size(shared)) in shared layers · \(StorageFormat.size(exclusive)) in exclusive layers")
                            } else { Text("Layer sharing unknown. Some storage may be used by other models.") }
                            Text(verbatim: tag.digest).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            Label(assessment(for: .ollama(tag)).classification.label, systemImage: "exclamationmark.triangle")
                                .font(.caption.bold())
                            Text("Restore: " + assessment(for: .ollama(tag)).restoration)
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
                Section("Hugging Face Hub") {
                    if let cacheError = state.cacheError { Text(verbatim: cacheError).foregroundStyle(.secondary) }
                    else if state.repositories.isEmpty { Text("No cached repositories found at \(hub.root.path).").foregroundStyle(.secondary) }
                    ForEach(state.repositories) { repo in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(verbatim: repo.identifier).font(.headline).textSelection(.enabled)
                                Spacer()
                                Button("Reveal") { model.reveal(repo.url) }
                                Button("Review deletion…") { review(.hub(repo)) }
                                    .disabled(hub.tool == nil || repo.revisions.isEmpty || state.deleting || state.refreshing)
                            }
                            Text("\(repo.revisions.count) cached revisions · \(StorageFormat.size(repo.localBytes)) allocated inside repository")
                            Text(verbatim: repo.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Label(assessment(for: .hub(repo)).classification.label, systemImage: "exclamationmark.triangle")
                                .font(.caption.bold())
                            Text("Restore: " + assessment(for: .hub(repo)).restoration)
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                    if !state.repositories.isEmpty {
                        Text(hub.tool == nil ? "Repository removal requires an installed hf CLI with cache rm support." :
                            "The hf CLI manages shared blobs across cached revisions and repositories.").foregroundStyle(.secondary)
                    }
                    Text("Deleting a repository removes only the selected cached copies. Shared blobs may remain, so logical size may not be recovered.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Local weights and checkpoints") {
                    if files.isEmpty { Text("No model files found among the largest scanned files or in supported inference directories.").foregroundStyle(.secondary) }
                    ForEach(files) { file in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(verbatim: file.url.lastPathComponent).font(.headline)
                                Spacer()
                                Text(StorageFormat.size(file.logicalBytes))
                                Button("Reveal") { model.reveal(file.url) }
                                Button("Review deletion…") { model.reviewSelection([file.url]) }.disabled(state.deleting)
                            }
                            Text(verbatim: file.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }.listStyle(.inset)
        }
        .task { await refresh() }
        .sheet(item: state.binding(\.selection)) { target in
            VStack(alignment: .leading, spacing: 14) {
                Text("Delete model permanently?").font(.title2.bold())
                Text(verbatim: target.id).font(.headline).textSelection(.enabled)
                Text(verbatim: target.location).foregroundStyle(.secondary).textSelection(.enabled)
                Label(assessment(for: target).classification.label, systemImage: "exclamationmark.triangle").font(.headline)
                Text(verbatim: assessment(for: target).consequences)
                Text(verbatim: assessment(for: target).restoration).foregroundStyle(.secondary).textSelection(.enabled)
                TextField("Type the exact model identifier", text: state.binding(\.typed))
                HStack {
                    Spacer()
                    Button("Cancel") { state.selection = nil }.keyboardShortcut(.cancelAction)
                    Button("Delete model", role: .destructive) {
                        let confirmation = state.typed
                        state.selection = nil
                        state.deleting = true
                        Task { await remove(target, confirmation: confirmation) }
                    }.disabled(state.typed != target.id)
                }
            }.padding(24).frame(width: 510)
        }
    }

    private func review(_ target: AIModelSelection) {
        state.typed = ""
        state.selection = target
    }

    private func assessment(for target: AIModelSelection) -> RecoverabilityAssessment {
        switch target {
        case .ollama(let tag):
            return RecoverabilityPolicy().assessManagedModel(
                identifier: tag.name, restoration: "Run ollama pull \(tag.name) while its registry still hosts it.")
        case .hub(let repo):
            return RecoverabilityPolicy().assessManagedModel(
                identifier: repo.identifier, restoration: "Re-download the required revision with hf download \(repo.identifier).")
        }
    }

    @MainActor private func refresh() async {
        guard !state.refreshing else { return }
        state.refreshing = true
        defer { state.refreshing = false }
        async let local = AIModelFiles.inferenceFiles()
        async let cached = hub.models()
        do { state.tags = try await ollama.models(); state.apiError = nil }
        catch { state.tags = []; state.apiError = "Local Ollama service unavailable. " + error.localizedDescription }
        do { state.repositories = try await cached; state.cacheError = nil }
        catch { state.repositories = []; state.cacheError = "Could not read \(hub.root.path). " + error.localizedDescription }
        state.inferenceFiles = await local
        state.lastRefresh = Date()
    }

    @MainActor private func remove(_ target: AIModelSelection, confirmation: String) async {
        let detail: String
        let status: String
        do {
            switch target {
            case .ollama(let tag): detail = try await ollama.delete(tag, confirmation: confirmation)
            case .hub(let repo):
                let cache = hub
                detail = try await Task.detached { try cache.delete(repo, confirmation: confirmation) }.value
            }
            status = "Completed"
        } catch {
            detail = error.localizedDescription
            status = "Failed"
        }
        model.recordOperation(action: "Delete model " + target.id, path: target.location, status: status, detail: detail)
        state.outcome = detail
        await refresh()
        state.deleting = false
    }
}
