import Foundation
import StorageCore
import SwiftUI

private struct SelectionReviewRow: Identifiable {
    let url: URL
    var id: URL { url }
    var ticket: SelectionDeletionTicket?
    var detail = "Waiting for inspection"
    var status = "Waiting"
}

@MainActor
private final class SelectionReviewState: ObservableObject {
    enum Phase { case preparing, review, executing, finished }

    @Published var mode = SelectionDeletionMode.trash
    @Published var rows: [SelectionReviewRow] = []
    @Published var phase = Phase.preparing
    @Published var count = 0
    @Published var confirming = false
    @Published var stopping = false
    @Published var work: Task<Void, Never>?

    func binding<T>(_ keyPath: ReferenceWritableKeyPath<SelectionReviewState, T>) -> Binding<T> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}

struct SelectionDeletionView: View {
    let urls: [URL]
    let onResult: (CleanupRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = SelectionReviewState()

    private var ready: [SelectionReviewRow] { state.rows.filter { $0.ticket != nil } }
    private var consequence: String {
        state.mode == .trash ? "Items stay on their source volume until you empty Trash. You can move them back from Trash." :
            "The selected items and their contents will be permanently removed. Recovery requires a separate backup."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.phase == .finished ? "Selection results" : "Review selected items").font(.title2.bold())
            if state.phase == .review {
                Picker("Action", selection: state.binding(\.mode)) {
                    ForEach(SelectionDeletionMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            if state.phase != .preparing { Text(consequence).foregroundStyle(.secondary) }
            List(state.rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(verbatim: row.url.lastPathComponent).font(.headline)
                        Spacer()
                        Text(row.status).font(.caption.bold())
                    }
                    Text(verbatim: row.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(verbatim: row.detail).font(.callout).textSelection(.enabled)
                }.padding(.vertical, 4)
            }.accessibilityLabel("Selected paths and review results")
            if state.phase == .preparing || state.phase == .executing {
                ProgressView(value: Double(state.count), total: Double(max(1, state.phase == .preparing ? state.rows.count : ready.count))) {
                    Text(state.stopping ? "Stopping…" : (state.phase == .preparing ? "Inspecting selected items…" : "Processing confirmed items…"))
                }
            }
            if state.phase == .review {
                Text("\(ready.count) of \(state.rows.count) selected items eligible · \(formattedTotal) logical size")
                    .font(.subheadline)
            }
            HStack {
                Spacer()
                if state.phase == .executing || state.phase == .preparing {
                    Button("Cancel") { state.stopping = true; state.work?.cancel() }
                        .disabled(state.stopping).keyboardShortcut(.cancelAction)
                } else {
                    Button(state.phase == .finished ? "Done" : "Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    if state.phase == .review {
                        Button(state.mode.rawValue + "…", role: .destructive) { state.confirming = true }
                            .disabled(ready.isEmpty)
                    }
                }
            }
        }
        .padding(20).frame(minWidth: 520, idealWidth: 650, minHeight: 370, idealHeight: 480)
        .interactiveDismissDisabled(state.phase == .executing)
        .onAppear { if state.work == nil { prepare() } }
        .onDisappear { state.work?.cancel() }
        .alert(state.mode == .trash ? "Move \(ready.count) selected item(s) to Trash?" : "Permanently delete \(ready.count) selected item(s)?",
               isPresented: state.binding(\.confirming)) {
            Button("Cancel", role: .cancel) {}
            Button(state.mode.rawValue, role: .destructive) { execute() }
        } message: { Text(consequence + " Only items marked Ready in the review will be processed.") }
    }

    private var formattedTotal: String {
        var bytes: Int64 = 0
        for row in ready {
            let (sum, overflow) = bytes.addingReportingOverflow(row.ticket?.logicalBytes ?? 0)
            guard !overflow else { return "Size unavailable" }
            bytes = sum
        }
        return StorageFormat.size(bytes)
    }

    @MainActor private func prepare() {
        state.rows = Array(Set(urls)).sorted { $0.path < $1.path }.map { SelectionReviewRow(url: $0) }
        state.work = Task { @MainActor in
            var accepted = Set<String>()
            for index in state.rows.indices {
                if Task.isCancelled { dismiss(); return }
                let url = state.rows[index].url
                let components = url.pathComponents.dropLast()
                var ancestor = ""
                let covered = components.contains { component in
                    ancestor = (ancestor as NSString).appendingPathComponent(component)
                    return accepted.contains(ancestor)
                }
                if covered {
                    state.rows[index].status = "Included"
                    state.rows[index].detail = "Included in a selected parent folder."
                } else {
                    let result = await worker { try SelectionDeletion().prepare(url, cancelled: { Task.isCancelled }) }
                    switch result {
                    case .success(let ticket):
                        state.rows[index].ticket = ticket
                        state.rows[index].status = "Ready"
                        state.rows[index].detail = "\(StorageFormat.size(ticket.logicalBytes)) logical · \(ticket.fileCount) file(s)"
                        if ticket.isFolder { accepted.insert(url.path) }
                    case .failure(let error):
                        state.rows[index].detail = error.localizedDescription
                        state.rows[index].status = "Blocked"
                    }
                }
                state.count += 1
            }
            if Task.isCancelled { dismiss() } else { state.phase = .review }
        }
    }

    @MainActor private func execute() {
        state.phase = .executing
        state.count = 0
        let action = state.mode
        state.work = Task { @MainActor in
            for index in state.rows.indices {
                guard let ticket = state.rows[index].ticket else { continue }
                let status: String
                let detail: String
                if Task.isCancelled {
                    status = "Cancelled"
                    detail = "Skipped before execution."
                } else {
                    state.rows[index].status = "Processing"
                    let result = await worker { try SelectionDeletion().execute(ticket, mode: action, cancelled: { Task.isCancelled }) }
                    switch result {
                    case .success(let outcome): status = "Completed"; detail = outcome
                    case .failure(let error):
                        status = Task.isCancelled ? "Cancelled" : "Failed"
                        detail = error.localizedDescription
                    }
                }
                state.rows[index].status = status
                state.rows[index].detail = detail
                onResult(CleanupRecord(id: UUID(), date: Date(), action: action.rawValue,
                                       path: ticket.url.path, status: status, detail: detail))
                state.count += 1
            }
            state.phase = .finished
        }
    }

    private func worker<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async -> Result<T, Error> {
        let task = Task.detached(priority: .userInitiated) { Result { try operation() } }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
