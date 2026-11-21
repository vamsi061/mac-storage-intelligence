import Foundation
import SwiftUI
import StorageCore

struct CleanupRecord: Identifiable, Codable {
    let id: UUID
    let date: Date
    let action: String
    let path: String
    var status: String
    var detail: String
}

enum CleanupOperation {
    case trash(TrashTicket)
    case package(PackageTicket)
    case packageBatch([PackageTicket])
}

struct CleanupConfirmation: Identifiable {
    let id = UUID()
    let action: String
    let target: URL
    let explanation: String
    let operation: CleanupOperation
}

struct CleanupHistoryView: View {
    let records: [CleanupRecord]

    var body: some View {
        if records.isEmpty {
            Text("Cleanup history will appear after your first action.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(records) { record in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(record.action).font(.headline)
                        Spacer()
                        Text(record.date.formatted()).foregroundStyle(.secondary)
                    }
                    Text(verbatim: record.path).textSelection(.enabled)
                    Text(record.status).font(.subheadline.bold())
                    Text(verbatim: record.detail).font(.callout).textSelection(.enabled)
                }.padding(.vertical, 5)
            }
        }
    }
}

struct ConfirmCleanupView: View {
    @ObservedObject var model: StorageModel
    let request: CleanupConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.action).font(.title2.bold())
            Text(verbatim: request.target.path).textSelection(.enabled)
            Text(verbatim: request.explanation).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel") { model.confirmation = nil }.keyboardShortcut(.cancelAction)
                Button(request.action, role: .destructive) { model.confirmCleanup(request) }
            }
        }
        .padding(24).frame(width: 520)
    }
}
