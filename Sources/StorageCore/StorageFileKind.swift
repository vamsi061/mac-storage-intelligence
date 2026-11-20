import Foundation

/// Conservative filename evidence for display and for protecting measured subtrees.
public enum StorageFileKind: String, Sendable, CaseIterable {
    case database = "Database or journal"
    case document = "Document"
    case diskImage = "Disk image"
    case virtualMachine = "Virtual machine disk or bundle"
    case model = "Model weights or checkpoint"
    case other = "Unclassified"

    private static let byExtension: [String: Self] = {
        let groups: [(Self, [String])] = [
            (.database, ["sqlite", "sqlite3", "db", "realm", "mdb", "ldb", "sst", "wt", "db3"]),
            (.document, ["doc", "docx", "pdf", "pages", "numbers", "key", "xls", "xlsx", "ppt", "pptx",
                         "odt", "ods", "rtf", "txt", "csv"]),
            (.diskImage, ["dmg", "iso", "sparseimage", "sparsebundle"]),
            (.virtualMachine, ["qcow", "qcow2", "raw", "vhd", "vhdx", "vdi", "vmdk", "utm", "pvm", "vmwarevm"]),
            (.model, ["gguf", "safetensors", "ckpt", "pt", "pth"])
        ]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { kind, suffixes in suffixes.map { ($0, kind) } })
    }()

    public static func inferred(from filename: String) -> Self {
        if filename == "PG_VERSION" || filename == "History" || filename == "Cookies" { return .database }
        if let dot = filename.lastIndex(of: "."),
           let kind = byExtension[filename[filename.index(after: dot)...].lowercased()] { return kind }
        if filename.contains("-") {
            let suffix = filename.suffix(8).lowercased()
            if suffix.hasSuffix("-wal") || suffix.hasSuffix("-shm") || suffix.hasSuffix("-journal") { return .database }
        }
        return .other
    }
}

public extension ScannedFile {
    var storageKind: StorageFileKind { .inferred(from: url.lastPathComponent) }
}
