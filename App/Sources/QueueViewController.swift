import AppKit
import RemoteCore

@MainActor
final class QueueViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var commander: CommanderWindowController?
    private var items: [QueueItem] = []
    private let table = NSTableView()
    private let titleLabel = NSTextField(labelWithString: "")

    private var samples: [UUID: (Date, Int64, Double)] = [:]

    override func loadView() {
        for (id, name, width) in [("op", "", CGFloat(24)), ("source", String(localized: "Source"), 260),
                                  ("target", String(localized: "Destination"), 260),
                                  ("done", String(localized: "Transferred"), 150),
                                  ("speed", String(localized: "Speed"), 90), ("progress", String(localized: "Progress"), 120)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = name
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        titleLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelSelected))
        let clear = NSButton(title: String(localized: "Clear Finished"), target: self, action: #selector(clearFinished))
        for b in [cancel, clear] { b.controlSize = .small; b.bezelStyle = .accessoryBarAction }
        let bar = NSStackView(views: [titleLabel, NSView(), cancel, clear])
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)

        let root = NSView()
        root.pinVertically([bar, scroll], flexible: scroll)
        view = root
        update([])
    }

    func update(_ new: [QueueItem]) {
        let now = Date()
        for item in new {
            let done = item.progress.doneBytes
            if let (t, b, speed) = samples[item.id] {
                let dt = now.timeIntervalSince(t)
                if dt >= 0.5 { samples[item.id] = (now, done, Double(done - b) / dt) } else { samples[item.id] = (t, b, speed) }
            } else {
                samples[item.id] = (now, done, 0)
            }
        }
        items = new
        titleLabel.stringValue = String(localized: "Queue (\(new.filter { $0.state == .queued || $0.state == .running }.count))")
        table.reloadData()
    }

    @objc private func cancelSelected() {
        for i in table.selectedRowIndexes where i < items.count { commander?.cancel(items[i].id) }
    }

    @objc private func clearFinished() { commander?.clearFinished() }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let id = column?.identifier.rawValue else { return nil }
        let item = items[row]
        let r = item.request
        let p = item.progress
        if id == "op" {
            let iv = NSImageView(image: NSImage(systemSymbolName: r.direction == .upload ? "arrow.up.circle" : "arrow.down.circle",
                                                accessibilityDescription: r.direction == .upload ? "Upload" : "Download")!)
            return iv
        }
        let text: String
        switch id {
        case "source": text = r.sources.count == 1 ? r.sources[0] : String(localized: "\(r.sources[0]) and \(r.sources.count - 1) more")
        case "target": text = r.targetDirectory
        case "done": text = "\(Format.size(p.doneBytes)) / \(Format.size(p.totalBytes))"
        case "speed":
            let s = samples[item.id]?.2 ?? 0
            text = item.state == .running && s > 0 ? "\(Format.size(Int64(s)))/s" : ""
        default:
            switch item.state {
            case .queued: text = String(localized: "Waiting")
            case .running: text = p.totalBytes > 0 ? "\(Int(Double(p.doneBytes) / Double(p.totalBytes) * 100))%" : "…"
            case .done: text = String(localized: "Completed")
            case .cancelled: text = String(localized: "Cancelled")
            case .failed(let m): text = String(localized: "Failed: \(m)")
            }
        }
        let f = NSTextField(labelWithString: text)
        f.lineBreakMode = .byTruncatingMiddle
        f.toolTip = text
        return f
    }
}
