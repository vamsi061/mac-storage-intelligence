import StorageCore
import SwiftUI

private struct CacheReview: Identifiable {
    let id = UUID()
    let tool: DeveloperCacheTool
    let ticket: DeveloperPackageTicket
}

private struct DockerRemoval: Identifiable {
    let id = UUID()
    let endpoint: DockerEndpoint
    let resource: DockerResource
}

@MainActor
private final class DeveloperState: ObservableObject {
    @Published var endpoints: [DockerEndpoint] = []
    @Published var resources: [DockerResource] = []
    @Published var dockerError: String?
    @Published var loadingDocker = false
    @Published var review: CacheReview?
    @Published var removal: DockerRemoval?
    @Published var message: String?

    func binding<T>(_ keyPath: ReferenceWritableKeyPath<DeveloperState, T>) -> Binding<T> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}

struct DeveloperStorageView: View {
    @ObservedObject var model: StorageModel
    @StateObject private var state = DeveloperState()

    private let cacheRules: [String: DeveloperCacheTool] = [
        "npm.content-cache": .npm, "pnpm.store": .pnpm, "yarn.cache": .yarn,
        "uv.cache": .uv, "homebrew.downloads": .brew
    ]
    private var matches: [CleanupRecommendation] {
        model.allRecommendations.filter { $0.id.hasPrefix("npm.") || $0.id.hasPrefix("pnpm.") ||
            $0.id.hasPrefix("yarn.") || $0.id.hasPrefix("uv.") || $0.id.hasPrefix("homebrew.") ||
            $0.id.hasPrefix("gradle.") || $0.id.hasPrefix("xcode.") || $0.id.hasPrefix("pip.") ||
            $0.id.hasPrefix("docker.") || $0.id.hasPrefix("colima.") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Developer storage").font(.title2.bold())
                Text("Only detected tools are shown. Cleanup uses each tool’s official mechanism or a reviewed command; model stores, VM disks and projects are never removed generically.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message = state.message { Text(verbatim: message).textSelection(.enabled).font(.callout) }

                if matches.isEmpty {
                    Text("No developer caches were measured in the monitored folders.").foregroundStyle(.secondary)
                } else {
                    ForEach(matches) { match in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(verbatim: match.title).font(.headline)
                                Spacer()
                                Text(StorageFormat.size(match.logicalBytes)).monospacedDigit()
                            }
                            Text(verbatim: match.target.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Label(match.risk.label, systemImage: "info.circle").font(.caption)
                            HStack {
                                if let tool = cacheRules[match.id] {
                                    Button("Review cleanup…") { review(tool, match) }
                                        .disabled(model.isBusy)
                                } else if PackageCleanup.supports(match) {
                                    Button("Review pip cleanup…") { model.reviewPackage(match) }
                                        .disabled(model.isBusy)
                                }
                                Button("Show in Finder") { model.reveal(match.target) }
                            }
                            Text(verbatim: match.nextAction).font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }

                Text("Docker and Colima").font(.title3.bold())
                if state.loadingDocker { ProgressView("Reading the local engine…").controlSize(.small) }
                if let error = state.dockerError { Text(verbatim: error).foregroundStyle(.secondary) }
                if state.endpoints.isEmpty && !state.loadingDocker {
                    Text("No running Docker or Colima engine socket was found. Installing or starting one enables this section.").foregroundStyle(.secondary)
                }
                ForEach(state.endpoints) { endpoint in
                    Text(endpoint.name).font(.headline)
                }
                ForEach(state.resources) { resource in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: resource.name).font(.headline)
                            Text(resource.kind.rawValue + " · " + resource.detail).font(.caption).foregroundStyle(.secondary)
                            if let bytes = resource.bytes { Text(StorageFormat.size(bytes)).font(.caption) }
                        }
                        Spacer()
                        if resource.canRemove {
                            Button("Remove…") { remove(resource) }.disabled(state.loadingDocker)
                        } else {
                            Text(resource.kind == .volume ? "Protected volume" : "Review in Docker")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
                Button("Refresh Docker") { Task { await loadDocker() } }.disabled(state.loadingDocker)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await loadDocker() }
        .sheet(item: state.binding(\.review)) { review in
            VStack(alignment: .leading, spacing: 12) {
                Text("Clean \(review.tool.rawValue) cache?").font(.title2.bold())
                Text(verbatim: review.ticket.summary).textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Cancel") { state.review = nil }.keyboardShortcut(.cancelAction)
                    Button("Clean cache", role: .destructive) { execute(review) }
                }
            }.padding(24).frame(width: 560)
        }
        .alert("Remove this Docker resource?", isPresented: Binding(
            get: { state.removal != nil }, set: { if !$0 { state.removal = nil } })) {
            Button("Cancel", role: .cancel) { state.removal = nil }
            Button("Remove", role: .destructive) { executeRemoval() }
        } message: {
            Text(state.removal.map { $0.resource.consequence } ?? "")
        }
    }

    private func review(_ tool: DeveloperCacheTool, _ match: CleanupRecommendation) {
        let cache = match.target
        state.message = "Inspecting the cache…"
        Task {
            do {
                let ticket = try await Task.detached(priority: .userInitiated) {
                    try DeveloperPackageTicket.prepare(tool, cache: cache)
                }.value
                state.review = CacheReview(tool: tool, ticket: ticket)
                state.message = nil
            } catch {
                state.message = error.localizedDescription
            }
        }
    }

    private func execute(_ review: CacheReview) {
        state.review = nil
        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) { try review.ticket.execute() }.value
                model.recordOperation(action: "Clean \(review.tool.rawValue) cache",
                                      path: review.ticket.summary, status: "Completed", detail: report)
                state.message = report
            } catch {
                model.recordOperation(action: "Clean \(review.tool.rawValue) cache",
                                      path: review.ticket.summary, status: "Failed", detail: error.localizedDescription)
                state.message = error.localizedDescription
            }
            await loadDocker()
        }
    }

    private func remove(_ resource: DockerResource) {
        for endpoint in state.endpoints {
            state.removal = DockerRemoval(endpoint: endpoint, resource: resource)
            return
        }
    }

    private func executeRemoval() {
        guard let removal = state.removal else { return }
        state.removal = nil
        state.loadingDocker = true
        Task {
            do {
                let inventory = DockerInventory(endpoint: removal.endpoint)
                let report = try await Task.detached(priority: .userInitiated) {
                    try inventory.remove(removal.resource)
                }.value
                model.recordOperation(action: "Remove Docker " + removal.resource.kind.rawValue,
                                      path: removal.resource.name, status: "Completed", detail: report)
                state.message = report
            } catch {
                model.recordOperation(action: "Remove Docker " + removal.resource.kind.rawValue,
                                      path: removal.resource.name, status: "Failed", detail: error.localizedDescription)
                state.message = error.localizedDescription
            }
            await loadDocker()
        }
    }

    @MainActor private func loadDocker() async {
        guard !state.loadingDocker else { return }
        state.loadingDocker = true
        defer { state.loadingDocker = false }
        let endpoints = await Task.detached(priority: .utility) { DockerEndpoint.discover() }.value
        state.endpoints = endpoints
        guard let endpoint = endpoints.first else {
            state.resources = []
            state.dockerError = nil
            return
        }
        do {
            let resources = try await Task.detached(priority: .utility) {
                try DockerInventory(endpoint: endpoint).resources()
            }.value
            state.resources = resources
            state.dockerError = nil
        } catch {
            state.resources = []
            state.dockerError = error.localizedDescription
        }
    }
}
