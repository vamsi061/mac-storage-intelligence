import AppKit
import Combine
import StorageCore

struct SelectionRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct CapacitySample: Identifiable {
    var id: Date { date }
    let date: Date
    let available: Int64
}

/// One full traversal at a time across the foreground folder and all volume inventories.
actor FullScanQueue {
    static let shared = FullScanQueue()
    private var running = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func scan(_ root: URL, options: ScanOptions,
              progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> ScanResult {
        if running { await withCheckedContinuation { waiting.append($0) } }
        running = true
        defer {
            if waiting.isEmpty { running = false } else { waiting.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await StorageScanner().scan(root: root, options: options, progress: progress)
    }
}
