import Darwin
import Foundation
#if !STORAGE_FIXTURE_RUNNER
import StorageCore
import XCTest
#endif

enum VolumeChecks {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run() throws {
        let service = VolumeService()
        let volumes = try service.mountedVolumes()
        guard !volumes.isEmpty, Set(volumes.map(\.id)).count == volumes.count else {
            throw Failure("Expected a nonempty list of distinct volume mount points.")
        }
        try checkSystemVolumeUsage(service)

        let folder = FileManager.default.temporaryDirectory
        let volume = try service.volume(containing: folder)
        var fs = statfs()
        guard statfs(folder.path, &fs) == 0 else { throw POSIXError(.EIO) }
        let expectedCapacity = Int64(fs.f_blocks * UInt64(fs.f_bsize))
        guard volume.id.isFileURL, !volume.name.isEmpty, volume.totalBytes == expectedCapacity,
              let available = volume.availableBytes, let used = volume.usedBytes,
              available >= 0, used >= 0, available <= expectedCapacity, used <= expectedCapacity else {
            throw Failure("The volume measurement is inconsistent with the filesystem.")
        }

        let missing = folder.appendingPathComponent(UUID().uuidString)
        do {
            _ = try service.volume(containing: missing)
        } catch {
            return
        }
        throw Failure("A missing path was reported as a measured volume.")
    }

    /// macOS df queries per-volume usage even when the startup volume shares free
    /// capacity with other APFS volumes. The sealed startup volume is stable here.
    private static func checkSystemVolumeUsage(_ service: VolumeService) throws {
        let root = try service.volume(containing: URL(fileURLWithPath: "/"))
        guard root.isReadOnly else { return }
        let df = Process()
        df.executableURL = URL(fileURLWithPath: "/bin/df")
        df.arguments = ["-kP", "/"]
        df.environment = ["LC_ALL": "C"]
        let output = Pipe()
        df.standardOutput = output
        try df.run()
        let report = output.fileHandleForReading.readDataToEndOfFile()
        df.waitUntilExit()
        let row = String(decoding: report, as: UTF8.self).split(separator: "\n").last
        let fields = row?.split(whereSeparator: \.isWhitespace) ?? []
        guard df.terminationStatus == 0, fields.count >= 6, let blocks = Int64(fields[2]),
              let measured = root.usedBytes, abs(measured - blocks * 1024) <= 1_048_576 else {
            throw Failure("Used space on the read-only startup volume disagrees with macOS df.")
        }
    }
}

#if !STORAGE_FIXTURE_RUNNER
final class VolumeServiceTests: XCTestCase {
    func testActualVolumeCapacityAndUnavailablePath() throws {
        try VolumeChecks.run()
    }
}
#endif
