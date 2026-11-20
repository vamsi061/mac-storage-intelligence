import StorageCore
import SwiftUI

/// Navigation is scoped to the scan result; choosing a tile never reads the filesystem.
struct FolderMap: View {
    let root: DirectoryNode
    @StateObject private var navigation = MapNavigation()

    private var folder: DirectoryNode { navigation.trail.last ?? root }
    private var visibleChildren: [DirectoryNode] {
        let children = folder.children.filter {
            navigation.filter.isEmpty || $0.url.displayName.localizedCaseInsensitiveContains(navigation.filter)
        }
        return navigation.byName ? children.sorted { $0.url.displayName.localizedStandardCompare($1.url.displayName) == .orderedAscending } : children
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(Array(([root] + navigation.trail).enumerated()), id: \.element.id) { index, node in
                        if index > 0 { Image(systemName: "chevron.right").accessibilityHidden(true) }
                        Button(node.url.displayName) {
                            navigation.trail = Array(navigation.trail.prefix(index))
                            navigation.filter = ""
                        }
                        .disabled(index == navigation.trail.count)
                    }
                }
            }
            .padding(.horizontal)
            if folder.logicalBytes > 0 {
                GeometryReader { geometry in
                    let tiles = FolderMapTile.layout(folder, in: CGRect(origin: .zero, size: geometry.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                            let title = tile.node?.url.displayName ?? "Other measured contents"
                            Button {
                                if let node = tile.node { descend(node) }
                            } label: {
                                Rectangle()
                                    .fill(tile.node == nil ? Color.secondary.opacity(0.18) : Color.accentColor.opacity(0.15 + Double(index % 4) * 0.09))
                                    .overlay(Rectangle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                                    .overlay {
                                        if tile.rect.width > 60 && tile.rect.height > 28 {
                                            Text(verbatim: title).font(.caption).lineLimit(2).padding(3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .disabled(tile.node == nil)
                            .help("\(title) · \(StorageFormat.size(tile.bytes))")
                            .accessibilityLabel("\(title), \(StorageFormat.size(tile.bytes))")
                            .frame(width: tile.rect.width, height: tile.rect.height)
                            .position(x: tile.rect.midX, y: tile.rect.midY)
                        }
                    }
                }
                .frame(height: 140)
                .padding(.horizontal)
                Text("Area shows logical size. Other measured contents includes direct files and folders outside the tiles.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            HStack {
                TextField("Filter subfolders", text: $navigation.filter)
                Picker("Sort", selection: $navigation.byName) {
                    Text("Largest first").tag(false)
                    Text("Name").tag(true)
                }.fixedSize()
            }.padding(.horizontal)
            List(visibleChildren) { node in
                Button { descend(node) } label: {
                    HStack {
                        Label(node.url.displayName, systemImage: "folder")
                        Spacer()
                        Text(StorageFormat.size(node.logicalBytes)).monospacedDigit()
                        Image(systemName: "chevron.right")
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .overlay { if visibleChildren.isEmpty { Text("No matching subfolders").foregroundStyle(.secondary) } }
        }
    }

    private func descend(_ node: DirectoryNode) {
        navigation.trail.append(node)
        navigation.filter = ""
    }
}

@MainActor private final class MapNavigation: ObservableObject {
    @Published var trail: [DirectoryNode] = []
    @Published var byName = false
    @Published var filter = ""
}
