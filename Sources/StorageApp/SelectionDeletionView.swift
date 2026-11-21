import Foundation
import StorageCore
import SwiftUI

private struct SelectionReviewRow: Identifiable {
    let url: URL
    var id: URL { url }
    var ticket: SelectionDeletionTicket?
    var assessment: RecoverabilityAssessment?
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
    @Published var highRisk = false
    @Published var typed = ""
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
    private let policy = RecoverabilityPolicy()

    private var eligible: [SelectionReviewRow] {
        state.rows.filter { $0.ticket != nil && $0.assessment?.isDeletable == true }
    }
    private var availableModes: [SelectionDeletionMode] {
        var modes = SelectionDeletionMode.allCases
        for row in eligible {
            let allowed = row.assessment?.allowedModes ?? []
            modes = modes.filter { allowed.contains($0) }
        }
        return modes
    }
    private var requiresTypedConfirmation: Bool {
        eligible.contains { $0.assessment?.requiresHighRiskConfirmation == true }
    }
    private var classifications: [RecoverabilityClass] {
        Array(Set(eligible.compactMap { $0.assessment?.classification })).sorted { $0.rawValue < $1.rawValue }
    }
    private var consequence: String {
        state.mode == .trash ? "Items stay on their source volume until you empty Trash. You can move them back from Trash." :
            "The selected items and their contents will be permanently removed. Recovery requires a separate backup or reinstall source."
    }
    private var restoration: String {
        Array(Set(eligible.compactMap { $0.assessment?.restoration })).joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.phase == .finished ? "Selection results" : "Review selected items").font(.title2.bold())
            if state.phase == .review {
                if availableModes.count > 1 {
                    Picker("Action", selection: state.binding(\.mode)) {
                        ForEach(availableModes, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                } else if let only = availableModes.first {
                    Text("Deletion method: \(only.rawValue)").font(.subheadline)
                }
            }
            if state.phase != .preparing { Text(consequence).foregroundStyle(.secondary) }
            List(state.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: row.url.lastPathComponent).font(.headline)
                        Spacer()
                        Text(row.status).font(.caption.bold())
                    }
                    Text(verbatim: row.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let assessment = row.assessment {
                        Label(assessment.classification.label, systemImage: icon(for: assessment.classification))
                            .font(.caption.bold())
                        Text(verbatim: assessment.evidence).font(.caption).foregroundStyle(.secondary)
                        Text("Restore: " + assessment.restoration).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(verbatim: row.detail).font(.callout).textSelection(.enabled)
                }.padding(.vertical, 5)
            }.accessibilityLabel("Selected paths, recoverability and review results")
            if state.phase == .preparing || state.phase == .executing {
                ProgressView(value: Double(state.count), total: Double(max(1, state.phase == .preparing ? state.rows.count : eligible.count))) {
                    Text(state.stopping ? "Stopping…" : (state.phase == .preparing ? "Inspecting selected items…" : "Processing confirmed items…"))
                }
            }
            if state.phase == .review {
                Text("\(eligible.count) of \(state.rows.count) selected items eligible · \(formattedTotal) logical")
                    .font(.subheadline)
                if requiresTypedConfirmation {
                    Label("At least one item has unknown or partial recoverability. A separate high-risk confirmation is required.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            if state.phase == .finished {
                Text(verbatim: DeletionOutcomeReporter.summarize(state.rows.map {
                    DeletionOutcomeRow(status: $0.status, logicalBytes: $0.ticket?.logicalBytes ?? 0, detail: $0.detail)
                })).font(.callout).textSelection(.enabled)
                if !restoration.isEmpty {
                    Text("Restoration: " + restoration).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
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
                        Button(state.mode.rawValue + "…", role: .destructive) { requestExecution() }
                            .disabled(eligible.isEmpty)
                    }
                }
            }
        }
        .padding(20).frame(minWidth: 560, idealWidth: 720, minHeight: 400, idealHeight: 520)
        .interactiveDismissDisabled(state.phase == .executing)
        .onAppear { if state.work == nil { prepare() } }
        .onDisappear { state.work?.cancel() }
        .alert(state.mode == .trash ? "Move \(eligible.count) selected item(s) to Trash?" : "Permanently delete \(eligible.count) selected item(s)?",
               isPresented: state.binding(\.confirming)) {
            Button("Cancel", role: .cancel) {}
            Button(state.mode.rawValue, role: .destructive) { execute() }
        } message: { Text(consequence + " Only items marked Ready in the review will be processed.") }
        .sheet(isPresented: state.binding(\.highRisk)) {
            highRiskConfirmation
        }
    }

    private var highRiskConfirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("High-risk deletion confirmation").font(.title2.bold())
            Text("\(eligible.count) item(s) · \(formattedTotal) estimated recovery · \(classifications.map(\.label).joined(separator: ", "))")
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(eligible.prefix(8)) { row in
                    Text(verbatim: row.url.path).font(.caption.monospaced()).textSelection(.enabled)
                }
                if eligible.count > 8 {
                    Text("and \(eligible.count - 8) more selected item(s)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(consequence).foregroundStyle(.secondary)
            Text("Consequences: " + Array(Set(eligible.compactMap { $0.assessment?.consequences })).joined(separator: " "))
                .font(.callout).textSelection(.enabled)
            if !restoration.isEmpty {
                Text("Restoration: " + restoration).font(.callout).textSelection(.enabled)
            }
            Text("Type DELETE to authorise this operation.").font(.callout.bold())
            TextField("DELETE", text: state.binding(\.typed))
                .textFieldStyle(.roundedBorder).frame(width: 220)
            HStack {
                Spacer()
                Button("Cancel") { state.highRisk = false; state.typed = "" }.keyboardShortcut(.cancelAction)
                Button(state.mode.rawValue, role: .destructive) {
                    state.highRisk = false
                    execute()
                }.disabled(state.typed != "DELETE")
            }
        }
        .padding(24).frame(width: 620)
    }

    private var formattedTotal: String {
        var bytes: Int64 = 0
        for row in eligible {
            let (sum, overflow) = bytes.addingReportingOverflow(row.ticket?.logicalBytes ?? 0)
            guard !overflow else { return "Size unavailable" }
            bytes = sum
        }
        return StorageFormat.size(bytes)
    }

    private func icon(for classification: RecoverabilityClass) -> String {
        switch classification {
        case .verifiedRecoverable: return "checkmark.seal"
        case .partiallyRecoverable: return "exclamationmark.triangle"
        case .unknownRecoverability: return "questionmark.circle"
        case .protected: return "lock.shield"
        }
    }

    private func requestExecution() {
        guard !eligible.isEmpty else { return }
        if requiresTypedConfirmation {
            state.typed = ""
            state.highRisk = true
        } else {
            state.confirming = true
        }
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
                    let assessment = policy.assessUserItem(at: url)
                    state.rows[index].assessment = assessment
                    guard assessment.isDeletable else {
                        state.rows[index].status = "Blocked"
                        state.rows[index].detail = assessment.evidence
                        state.count += 1
                        continue
                    }
                    let result = await worker { try SelectionDeletion().prepare(url, cancelled: { Task.isCancelled }) }
                    switch result {
                    case .success(let ticket):
                        state.rows[index].ticket = ticket
                        state.rows[index].status = "Ready"
                        state.rows[index].detail = "\(StorageFormat.size(ticket.logicalBytes)) logical · \(ticket.fileCount) file(s) · \(assessment.methodSummary)"
                        if ticket.isFolder { accepted.insert(url.path) }
                    case .failure(let error):
                        state.rows[index].detail = error.localizedDescription
                        state.rows[index].status = "Blocked"
                    }
                }
                state.count += 1
            }
            if Task.isCancelled { dismiss(); return }
            let modes = availableModes
            if !modes.contains(state.mode) { state.mode = modes.first ?? .trash }
            state.phase = .review
        }
    }

    @MainActor private func execute() {
        state.phase = .executing
        state.count = 0
        state.typed = ""
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
