import CoreGraphics
import Foundation

public struct FolderMapTile {
    public let node: DirectoryNode?
    public let bytes: Int64
    public let rect: CGRect

    public static func layout(_ parent: DirectoryNode, in bounds: CGRect) -> [Self] {
        typealias Item = (node: DirectoryNode?, bytes: Int64)
        var items: [Item] = parent.children.prefix(24).filter { $0.logicalBytes > 0 }.map { ($0, $0.logicalBytes) }
        let remaining = parent.logicalBytes - items.reduce(0) { $0 + $1.bytes }
        if remaining > 0 { items.append((nil, remaining)) }
        items.sort { $0.bytes > $1.bytes }
        var tiles: [Self] = []
        // Bisect near half of the group's total weight along its longer axis.
        func split(_ group: ArraySlice<Item>, total: Double, rect: CGRect) {
            guard let first = group.first, total > 0 else { return }
            if group.count == 1 {
                tiles.append(Self(node: first.node, bytes: first.bytes, rect: rect))
                return
            }
            var weight = Double(first.bytes)
            var cut = group.startIndex + 1
            while cut < group.endIndex - 1 && abs(weight + Double(group[cut].bytes) - total / 2) < abs(weight - total / 2) {
                weight += Double(group[cut].bytes)
                cut += 1
            }
            let wide = rect.width >= rect.height
            let (a, b) = rect.divided(atDistance: (wide ? rect.width : rect.height) * CGFloat(weight / total), from: wide ? .minXEdge : .minYEdge)
            split(group[..<cut], total: weight, rect: a)
            let rest = group[cut...]
            split(rest, total: rest.reduce(0) { $0 + Double($1.bytes) }, rect: b)
        }
        split(items[...], total: Double(parent.logicalBytes), rect: bounds)
        return tiles
    }
}
