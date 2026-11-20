import StorageCore
import SwiftUI

struct Dashboard: View {
    @ObservedObject var model: StorageModel
    @Binding var showingCoverage: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Volume capacity").font(.title2.bold())
                        Spacer()
                        if !model.volumes.isEmpty {
                            Picker("Volume", selection: $model.selectedVolumeID) {
                                ForEach(model.volumes) { volume in
                                    Text(verbatim: volumeTitle(volume)).tag(Optional(volume.id))
                                }
                            }
                            .labelsHidden().frame(maxWidth: 235)
                            .accessibilityLabel("Volume for capacity reporting")
                        }
                        Button(action: model.refreshVolumes) {
                            Label("Refresh capacity", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                        }
                        .disabled(model.refreshingVolumes)
                        .help("Refresh mounted volumes and capacity")
                    }
                    if let volume = model.selectedVolume {
                        VolumeCapacityView(volume: volume)
                        Button("Scan this volume…") { model.chooseVolumeFolder(volume.id) }
                            .disabled(model.isBusy)
                    } else if model.refreshingVolumes {
                        ProgressView("Reading mounted volumes…").controlSize(.small)
                    } else {
                        Text(model.volumeError ?? "No mounted volumes are available.").foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Last folder scan").font(.title2.bold())
                        Spacer()
                        if model.result != nil {
                            Button("View coverage") { showingCoverage = true }
                        }
                    }
                    if let result = model.result {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.tint)
                            Text(verbatim: result.root.url.path)
                                .font(.headline).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            Spacer()
                        }
                        Text(result.completedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 20) {
                            Metric(title: "Logical size", value: StorageFormat.size(result.root.logicalBytes))
                            Metric(title: "Allocated estimate", value: StorageFormat.size(result.root.allocatedBytes))
                            Metric(title: "Files counted", value: result.root.fileCount.formatted())
                        }
                        if result.issueCount > 0 {
                            Label("\(result.issueCount.formatted()) scan issues. Some entries could not be measured.", systemImage: "exclamationmark.triangle")
                                .font(.callout)
                        }
                        if !result.root.children.isEmpty {
                            Text("Largest measured subfolders").font(.headline)
                            ForEach(result.root.children.prefix(5)) { child in
                                HStack {
                                    Text(verbatim: child.url.displayName).lineLimit(1)
                                    Spacer()
                                    Text(StorageFormat.size(child.logicalBytes)).monospacedDigit()
                                }
                                .help(child.url.path)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        if let first = result.largestFiles.first {
                            HStack {
                                Image(systemName: "doc").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Largest file").font(.caption).foregroundStyle(.secondary)
                                    Text(verbatim: first.url.displayName).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(StorageFormat.size(first.logicalBytes)).monospacedDigit()
                            }
                            .help(first.url.path)
                        }
                        HStack {
                            Button("Browse folder tree") { model.page = .folders }
                            Button("View largest files") { model.page = .files }
                        }
                        if !model.recommendations.isEmpty {
                            Button("Review cleanup matches (\(model.recommendations.count.formatted()))") {
                                model.page = .cleanup
                            }
                        }
                    } else {
                        if let date = model.lastCompletedAt {
                            Text("Last completed \(date.formatted(date: .abbreviated, time: .standard)). Scan again to browse the results.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Choose a folder to see how much space its files and subfolders use.")
                                .foregroundStyle(.secondary)
                        }
                        Button("Scan Folder…", action: model.chooseFolder)
                            .buttonStyle(.borderedProminent).disabled(model.isBusy)
                    }
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func volumeTitle(_ volume: StorageVolume) -> String {
        let sharesName = model.volumes.contains { $0.id != volume.id && $0.name == volume.name }
        return sharesName ? "\(volume.name) (\(volume.id.path))" : volume.name
    }
}

private struct VolumeCapacityView: View {
    let volume: StorageVolume

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: volume.isRemovable ? "externaldrive.fill" : "internaldrive.fill")
                    .font(.system(size: 34)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: volume.name).font(.title3.weight(.semibold))
                    Text(verbatim: volume.id.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                if volume.isReadOnly {
                    Label("Read-only", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 20) {
                Metric(title: "Used by volume", value: StorageFormat.size(volume.usedBytes))
                Metric(title: "Available", value: StorageFormat.size(volume.availableBytes))
                Metric(title: "Total capacity", value: StorageFormat.size(volume.totalBytes))
            }
            if let total = volume.totalBytes, total > 0,
               let available = volume.availableBytes, (0...total).contains(available) {
                let unavailable = total - available
                let fraction = Double(unavailable) / Double(total)
                let percent = fraction.formatted(.percent.precision(.fractionLength(0...1)))
                VStack(alignment: .leading, spacing: 6) {
                    if let used = volume.usedBytes, used >= 0, used <= unavailable {
                        CapacityChart(total: total, used: used, available: available)
                            .id(volume.id)
                    } else {
                        ProgressView(value: fraction)
                            .accessibilityLabel("Capacity unavailable to this volume")
                            .accessibilityValue(percent)
                    }
                    Text("\(percent) of capacity is unavailable to this volume.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let used = volume.usedBytes, used >= 0, used < unavailable {
                        Text("\(StorageFormat.size(unavailable - used)) is shared or otherwise reserved. This can include usage by other APFS volumes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("macOS reports these values for the volume. A folder scan measures files within the folder you choose.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private enum CapacityPart: String, CaseIterable {
    case used = "Used by volume"
    case shared = "Shared or reserved"
    case free = "Available"

    var color: Color {
        switch self {
        case .used: return .accentColor
        case .shared: return .orange
        case .free: return .green
        }
    }
}

@MainActor private final class ChartSelection: ObservableObject {
    @Published var part = CapacityPart.used
}

private struct CapacityChart: View {
    let total: Int64
    let used: Int64
    let available: Int64
    @StateObject private var selection = ChartSelection()

    private func bytes(_ part: CapacityPart) -> Int64 {
        switch part {
        case .used: return used
        case .shared: return total - available - used
        case .free: return available
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(CapacityPart.allCases, id: \.self) { part in
                        Button { selection.part = part } label: {
                            Rectangle().fill(part.color)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(part.rawValue)
                        .accessibilityValue(StorageFormat.size(bytes(part)))
                        .frame(width: geometry.size.width * CGFloat(Double(bytes(part)) / Double(total)))
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 4))
            }.frame(height: 18)
            Picker("Storage distribution", selection: $selection.part) {
                ForEach(CapacityPart.allCases, id: \.self) { part in Text(part.rawValue).tag(part) }
            }.pickerStyle(.segmented).labelsHidden()
            Text("\(selection.part.rawValue) · \(StorageFormat.size(bytes(selection.part))) · \((Double(bytes(selection.part)) / Double(total)).formatted(.percent.precision(.fractionLength(1))))")
                .font(.callout).monospacedDigit()
        }
    }
}
