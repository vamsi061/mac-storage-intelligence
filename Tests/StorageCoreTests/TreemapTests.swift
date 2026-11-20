import CoreGraphics
import Foundation
#if !STORAGE_FIXTURE_RUNNER
@testable import StorageCore
import XCTest
#endif

enum TreemapChecks {
    static func run() throws {
        func node(_ name: String, bytes: Int64, children: [DirectoryNode] = []) -> DirectoryNode {
            DirectoryNode(url: URL(fileURLWithPath: "/fixture/" + name), logicalBytes: bytes, allocatedBytes: bytes,
                          fileCount: 1, children: children)
        }
        let children = (1...30).map { node("folder-\($0)", bytes: Int64(31 - $0)) }
        let root = node("root", bytes: 500, children: children)
        let bounds = CGRect(x: 2, y: 5, width: 700, height: 540)
        let tiles = FolderMapTile.layout(root, in: bounds)
        guard tiles.count == 25, tiles.compactMap(\.node).count == 24,
              tiles.map(\.bytes).reduce(0, +) == root.logicalBytes else { throw Failure.accounting }
        for (index, tile) in tiles.enumerated() {
            let expected = bounds.width * bounds.height * Double(tile.bytes) / Double(root.logicalBytes)
            guard abs(tile.rect.width * tile.rect.height - expected) < 0.001,
                  bounds.insetBy(dx: -0.001, dy: -0.001).contains(tile.rect) else { throw Failure.area }
            for other in tiles.dropFirst(index + 1) {
                let intersection = tile.rect.intersection(other.rect)
                guard intersection.isNull || intersection.width * intersection.height < 0.001 else { throw Failure.overlap }
            }
        }
        guard FolderMapTile.layout(node("empty", bytes: 0), in: bounds).isEmpty else { throw Failure.accounting }
    }
    private enum Failure: Error { case accounting, area, overlap }
}

#if !STORAGE_FIXTURE_RUNNER
final class TreemapTests: XCTestCase {
    func testProportionalRectanglesAndRemainder() throws { try TreemapChecks.run() }
}
#endif
