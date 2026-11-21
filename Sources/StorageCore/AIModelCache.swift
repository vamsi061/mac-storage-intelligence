import Darwin
import Foundation

public struct HuggingFaceModel: Identifiable, Sendable {
    public let url: URL
    public var id: String { url.path }
    public let identifier: String
    public let revisions: [String]
    public let localBytes: Int64?
    fileprivate let inode: ino_t
    fileprivate let device: dev_t
}

public struct HuggingFaceCache: Sendable {
    public let root: URL
    public let tool: URL?

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let base = env["HF_HOME"].flatMap(Self.absolute) ?? env["XDG_CACHE_HOME"].flatMap(Self.absolute)?.appendingPathComponent("huggingface")
            ?? home.appendingPathComponent(".cache/huggingface")
        root = env["HF_HUB_CACHE"].flatMap(Self.absolute) ?? env["HUGGINGFACE_HUB_CACHE"].flatMap(Self.absolute) ?? base.appendingPathComponent("hub")
        let paths = [home.appendingPathComponent(".local/bin/hf"), URL(fileURLWithPath: "/opt/homebrew/bin/hf"),
                     URL(fileURLWithPath: "/usr/local/bin/hf")] +
            (env["PATH"] ?? "").components(separatedBy: ":").compactMap(Self.absolute).map { $0.appendingPathComponent("hf") }
        tool = paths.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    init(root: URL, tool: URL?) { self.root = root; self.tool = tool }

    private static func absolute(_ path: String) -> URL? {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }

    public func models() async throws -> [HuggingFaceModel] {
        let fm = FileManager.default
        let entries: [URL]
        do { entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
        var result = [HuggingFaceModel]()
        for folder in entries where folder.lastPathComponent.hasPrefix("models--") {
            try Task.checkCancellation()
            var info = stat()
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            let parts = String(folder.lastPathComponent.dropFirst(8)).components(separatedBy: "--")
            guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { continue }
            let snapshots = folder.appendingPathComponent("snapshots")
            let revisions = (try? fm.contentsOfDirectory(atPath: snapshots.path)) ?? []
            let summary = try? await StorageScanner().scan(root: folder, options: .init(largestFileLimit: 0, directoryLimit: 1, issueLimit: 0))
            result.append(HuggingFaceModel(url: folder, identifier: "model/" + parts.joined(separator: "/"),
                                           revisions: revisions.sorted(), localBytes: summary.flatMap { $0.issueCount == 0 ? $0.root.allocatedBytes : nil },
                                           inode: info.st_ino, device: info.st_dev))
        }
        return result.sorted { $0.identifier < $1.identifier }
    }

    public func delete(_ selected: HuggingFaceModel, confirmation: String) throws -> String {
        guard let tool, confirmation == selected.identifier else { throw AIModelError("The hf CLI and exact repository identifier are required.") }
        guard selected.url.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
              !selected.revisions.isEmpty else { throw AIModelError("Refresh the cache and review the repository again.") }
        var info = stat()
        let snapshots = selected.url.appendingPathComponent("snapshots")
        guard lstat(selected.url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_ino == selected.inode, info.st_dev == selected.device,
              try FileManager.default.contentsOfDirectory(atPath: snapshots.path).sorted() == selected.revisions else {
            throw AIModelError("The cached repository changed. Refresh and review it again.")
        }
        guard try StorageActivitySnapshot.capture(candidates: [selected.url]).protectionReason(for: selected.url) == nil else {
            throw AIModelError("A visible process is using this cached repository.")
        }
        let before = modelFreeSpace(root)
        let process = Process()
        process.executableURL = tool
        process.arguments = ["cache", "rm", selected.identifier, "--cache-dir", root.path, "--yes"]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        process.environment = env
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let absent = lstat(selected.url.path, &info) != 0 && errno == ENOENT
        let report = (absent ? "Verified removal of \(selected.identifier)." : "The cached repository removal could not be verified.") +
            " " + modelSpaceReport(before: before, after: modelFreeSpace(root))
        guard process.terminationStatus == 0, absent else {
            throw AIModelError("hf cache rm exited with status \(process.terminationStatus). " +
                               String(decoding: data.suffix(1200), as: UTF8.self) + " " + report)
        }
        return report
    }
}

public enum AIModelFiles {
    public static func isWeight(_ file: URL) -> Bool {
        StorageFileKind.inferred(from: file.lastPathComponent) == .model ||
            ["ggml", "onnx", "tflite", "mlmodel", "h5", "pb", "bin"].contains(file.pathExtension.lowercased()) &&
            (file.pathExtension.lowercased() != "bin" || ["pytorch_model", "ggml-model", "model-"].contains { file.lastPathComponent.hasPrefix($0) })
    }

    /// Shared, content-addressed caches are managed by their owning tool.
    public static func isManaged(_ url: URL, cache: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        return url.path.hasPrefix(cache.path + "/") || parts.contains(".ollama") || parts.contains { $0.hasPrefix("models--") } ||
            parts.contains("blobs") || parts.contains("snapshots")
    }
}

public extension AIModelFiles {
    static func inferenceFiles() async -> [ScannedFile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let locations = [".lmstudio/models", ".cache/lm-studio/models", "Library/Application Support/Jan/data/models",
                         "Library/Application Support/nomic.ai/GPT4All"]
        var files = [ScannedFile]()
        for path in locations {
            if Task.isCancelled { break }
            let folder = home.appendingPathComponent(path)
            if let result = try? await StorageScanner().scan(root: folder, options: .init(largestFileLimit: 1000, directoryLimit: 1)) {
                files += result.largestFiles.filter { isWeight($0.url) }
            }
        }
        return files
    }
}
