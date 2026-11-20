import Darwin
import Foundation

/// Only candidate roots with positive evidence are retained. A missing match is unknown.
public struct StorageActivitySnapshot: Sendable {
    public static let unknown = Self(activeDirectories: [])
    private let activePaths: Set<String>

    public init(activeDirectories: Set<URL>) {
        activePaths = Set(activeDirectories.map { $0.standardizedFileURL.path })
    }

    public func protectionReason(for target: URL) -> String? {
        activePaths.contains(target.standardizedFileURL.path)
            ? "A visible process had a working directory or open file here during analysis." : nil
    }

    public static func capture(candidates: [URL]) throws -> Self {
        guard !candidates.isEmpty else { return .unknown }
        let targets = Dictionary(grouping: candidates, by: { candidate in
            guard let physical = realpath(candidate.path, nil) else { return candidate.path }
            defer { free(physical) }
            return String(cString: physical)
        })
        var active = Set<URL>()
        func observe(_ raw: String) {
            var path = raw[...]
            while !path.isEmpty {
                if let matches = targets[String(path)] { active.formUnion(matches) }
                guard let slash = path.lastIndex(of: "/") else { break }
                path = path[..<slash]
            }
        }
        func decode(_ vnode: inout vnode_info_path) -> String? {
            withUnsafeBytes(of: &vnode.vip_path) { bytes in
                guard let end = bytes.firstIndex(of: 0), end > 0 else { return nil }
                return String(bytes: bytes[..<end], encoding: .utf8)
            }
        }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return .unknown }
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let listed = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let visible = pids.prefix(max(0, min(Int(listed), pids.count)))
        for pid in [getpid()] + visible.filter({ $0 > 0 && $0 != getpid() }) {
            try Task.checkCancellation()
            if DispatchTime.now().uptimeNanoseconds >= deadline || active.count == candidates.count { break }
            var cwd = proc_vnodepathinfo()
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &cwd, Int32(MemoryLayout.size(ofValue: cwd))) == MemoryLayout.size(ofValue: cwd),
               let path = decode(&cwd.pvi_cdir) { observe(path) }
            let stride = MemoryLayout<proc_fdinfo>.stride
            let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard needed > 0 else { continue }
            var files = [proc_fdinfo](repeating: proc_fdinfo(), count: min(8192, Int(needed) / stride + 16))
            let bytes = files.withUnsafeMutableBytes {
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            for file in files.prefix(max(0, Int(bytes) / stride)) where file.proc_fdtype == PROX_FDTYPE_VNODE {
                try Task.checkCancellation()
                if DispatchTime.now().uptimeNanoseconds >= deadline { break }
                var detail = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout.size(ofValue: detail))
                if proc_pidfdinfo(pid, file.proc_fd, PROC_PIDFDVNODEPATHINFO, &detail, size) == size,
                   let path = decode(&detail.pvip) { observe(path) }
            }
        }
        return Self(activeDirectories: active)
    }
}
