import AppKit
import RemoteCore

@MainActor
final class TextEditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSMenuItemValidation {
    static let wrapKey = "editorWrapsLines"

    let localURL: URL
    let remotePath: String
    var onClose: () -> Void = {}
    private var file: TextFile
    private let textView: NSTextView
    private let scroll: NSScrollView
    private let status = NSTextField(labelWithString: "")
    private var uploadStatus = ""

    init(localURL: URL, remotePath: String, file: TextFile, host: String) {
        self.localURL = localURL
        self.remotePath = remotePath
        self.file = file
        scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = (remotePath as NSString).lastPathComponent
        window.subtitle = "\(host):\(RemotePath.parent(remotePath))"
        window.setFrameAutosaveName("TextEditor")
        super.init(window: window)
        window.delegate = self

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.string = file.text
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.delegate = self
        textView.setAccessibilityLabel(String(localized: "Text of \((remotePath as NSString).lastPathComponent)"))
        setWrap(UserDefaults.standard.object(forKey: Self.wrapKey) as? Bool ?? true)

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [scroll, status])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        status.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 10).isActive = true
        status.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor, constant: -10).isActive = true
        window.contentView = stack
        window.initialFirstResponder = textView
        updateStatus()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setWrap(_ wrap: Bool) {
        let container = textView.textContainer!
        container.widthTracksTextView = wrap
        container.containerSize = NSSize(width: wrap ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude,
                                         height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = !wrap
        textView.autoresizingMask = wrap ? [.width] : [.width, .height]
        scroll.hasHorizontalScroller = !wrap
        if wrap { textView.frame.size.width = scroll.contentSize.width }
    }

    private var wraps: Bool { textView.textContainer?.widthTracksTextView ?? true }

    @objc func toggleWrap(_ sender: Any?) {
        setWrap(!wraps)
        UserDefaults.standard.set(wraps, forKey: Self.wrapKey)
    }

    @objc func goToLine(_ sender: Any?) {
        Task {
            guard let answer = await Alerts.ask(String(localized: "Go to line"), ok: String(localized: "Go"), in: window),
                  let line = Int(answer.trimmingCharacters(in: .whitespaces)), line > 0 else { return }
            let text = textView.string as NSString
            var location = 0
            for _ in 1..<line {
                let r = text.lineRange(for: NSRange(location: location, length: 0))
                guard NSMaxRange(r) < text.length else { break }
                location = NSMaxRange(r)
            }
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            window?.makeFirstResponder(textView)
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let data = file.encode(textView.string) else {
            let a = NSAlert()
            a.messageText = String(localized: "The text cannot be saved as \(file.encodingName).")
            a.informativeText = String(localized: "Some characters do not exist in that encoding. Save the file as UTF-8 instead?")
            a.addButton(withTitle: String(localized: "Save as UTF-8"))
            a.addButton(withTitle: String(localized: "Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
            file.encoding = .utf8
            file.bom = false
            return saveDocument(sender)
        }
        do {
            try data.write(to: localURL)
            window?.isDocumentEdited = false
            updateStatus()
        } catch {
            Task { await Alerts.error(error, in: window) }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleWrap(_:)) { item.state = wraps ? .on : .off }
        return true
    }

    func setUploadStatus(_ text: String) {
        uploadStatus = text
        updateStatus()
    }

    private func updateStatus() {
        let text = textView.string as NSString
        let caret = min(textView.selectedRange().location, text.length)
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let line = text.substring(to: lineStart).utf16.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        let parts = [String(localized: "Line \(line), Column \(caret - lineStart + 1)"), file.encodingName,
                     file.lineEnding.rawValue, uploadStatus].filter { !$0.isEmpty }
        status.stringValue = parts.joined(separator: "  ·  ")
    }

    func textDidChange(_ notification: Notification) {
        window?.isDocumentEdited = true
        updateStatus()
    }

    func textViewDidChangeSelection(_ notification: Notification) { updateStatus() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.isDocumentEdited else { return true }
        let a = NSAlert()
        a.messageText = String(localized: "Save changes to “\((remotePath as NSString).lastPathComponent)” before closing?")
        a.informativeText = String(localized: "Saved changes are uploaded to the server.")
        a.addButton(withTitle: String(localized: "Save"))
        a.addButton(withTitle: String(localized: "Don’t Save"))
        a.addButton(withTitle: String(localized: "Cancel"))
        switch a.runModal() {
        case .alertFirstButtonReturn:
            saveDocument(nil)
            return !sender.isDocumentEdited
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    #if DEBUG
    func debugInsertAndSave(_ text: String) {
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText(text, replacementRange: textView.selectedRange())
        saveDocument(nil)
    }
    #endif
}
