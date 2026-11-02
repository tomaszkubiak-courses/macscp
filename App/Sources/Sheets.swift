import RemoteCore
import SwiftUI

struct TransferSheet: View {
    let direction: TransferDirection
    let count: Int
    let first: String
    @State var target: String
    @State var options: TransferOptions
    @State private var showOptions = false
    let done: ((String, TransferOptions)?) -> Void

    init(direction: TransferDirection, count: Int, first: String, target: String, options: TransferOptions,
         done: @escaping ((String, TransferOptions)?) -> Void) {
        self.direction = direction; self.count = count; self.first = first
        _target = State(initialValue: target)
        _options = State(initialValue: options)
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(direction == .upload
                 ? (count == 1 ? "Upload “\(first)” to remote folder:" : "Upload \(count) items to remote folder:")
                 : (count == 1 ? "Download “\(first)” to local folder:" : "Download \(count) items to local folder:"))
                .font(.headline)
            TextField("", text: $target).textFieldStyle(.roundedBorder)
            DisclosureGroup("Transfer settings", isExpanded: $showOptions) {
                Form { TransferOptionsForm(options: $options) }.formStyle(.grouped)
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") { done((target, options)) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

@MainActor
@Observable
final class PropertiesModel {
    let items: [PaneItem]
    let directory: String
    let isRemote: Bool
    var mode: UInt16
    var addX = true
    var recursive = false
    var owner: String
    var group: String
    let originalOwner: String
    let originalGroup: String

    let mixed: Bool

    init(items: [PaneItem], directory: String, isRemote: Bool) {
        self.items = items; self.directory = directory; self.isRemote = isRemote
        mode = items.first?.mode ?? 0o644
        mixed = Set(items.map(\.mode)).count > 1
        originalOwner = Set(items.map(\.owner)).count == 1 ? items.first?.owner ?? "" : ""
        originalGroup = Set(items.map(\.group)).count == 1 ? items.first?.group ?? "" : ""
        owner = originalOwner
        group = originalGroup
    }

    private var newOwner: String? {
        let o = owner.trimmingCharacters(in: .whitespaces)
        return o.isEmpty || o == originalOwner ? nil : o
    }

    private var newGroup: String? {
        let g = group.trimmingCharacters(in: .whitespaces)
        return g.isEmpty || g == originalGroup ? nil : g
    }

    var summary: String {
        let dirs = items.filter(\.isDirectory).count
        let files = items.count - dirs
        if items.count == 1 { return items[0].name }
        return String(localized: "\(files) files, \(dirs) folders")
    }

    var size: Int64 { items.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size } }

    func apply(using source: PaneSource) async throws {
        for item in items {
            try await apply(RemotePath.join(directory, item.name), isDirectory: item.isDirectory && !item.isLink, source)
        }
    }

    private func apply(_ path: String, isDirectory: Bool, _ source: PaneSource) async throws {
        let m = isDirectory && addX ? Permissions(mode).addingExecuteWhereReadable.mode : mode
        try await source.setPermissions(path, m)
        if source.canChangeOwner, newOwner != nil || newGroup != nil {
            try await source.setOwner(path, owner: newOwner, group: newGroup)
        }
        guard isDirectory, recursive else { return }
        for child in try await source.list(path) where !child.isLink {
            try await apply(RemotePath.join(path, child.name), isDirectory: child.isDirectory, source)
        }
    }
}

struct PropertiesView: View {
    @Bindable var model: PropertiesModel
    var canChangeOwner = false
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(model.summary, systemImage: model.items.count == 1 && model.items[0].isDirectory ? "folder" : "doc.on.doc")
                .font(.headline)
            Grid(alignment: .leading, verticalSpacing: 6) {
                GridRow { Text("Location").foregroundStyle(.secondary); Text(model.directory).textSelection(.enabled) }
                GridRow { Text("Size").foregroundStyle(.secondary); Text("\(Format.size(model.size)) (\(model.size) B)") }
                if canChangeOwner {
                    GridRow {
                        Text("Owner").foregroundStyle(.secondary)
                        TextField("Owner", text: $model.owner, prompt: Text("Unchanged")).labelsHidden()
                    }
                    GridRow {
                        Text("Group").foregroundStyle(.secondary)
                        TextField("Group", text: $model.group, prompt: Text("Unchanged")).labelsHidden()
                    }
                } else if let first = model.items.first {
                    GridRow { Text("Owner").foregroundStyle(.secondary); Text(first.owner) }
                    GridRow { Text("Group").foregroundStyle(.secondary); Text(first.group) }
                }
            }
            Divider()
            Text(model.mixed ? "Permissions (differ across selection)" : "Permissions").font(.subheadline)
            PermissionsGrid(mode: $model.mode)
            Toggle("Add X to directories", isOn: $model.addX)
            if model.items.contains(where: \.isDirectory) {
                Toggle(canChangeOwner ? "Apply recursively" : "Set permissions recursively", isOn: $model.recursive)
            }
            HStack {
                Spacer()
                Button("Cancel") { done(false) }.keyboardShortcut(.cancelAction)
                Button("OK") { done(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
