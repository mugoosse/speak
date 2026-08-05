import AppKit

/// Settings for what happens to a transcript after the speech engine is done
/// with it: the optional polishing pass, and the user's own dictionary.
///
/// One pane rather than two tabs. They are separate features but they explain
/// each other: terms only do anything while polishing, and the point of
/// corrections is that they run afterwards. Split across two tabs, neither half
/// says what it is relative to.
@MainActor
final class TextPane: Pane, NSTableViewDataSource, NSTableViewDelegate,
                      NSTextFieldDelegate {
    private var entries: [CustomDictionary.Entry] = []
    /// Which half of the dictionary the table is showing. Held here rather than
    /// read back off the control so `rebuild()` does not snap it back to Terms.
    private var showing: CustomDictionary.Kind = .term
    private var table: NSTableView!
    private var empty: NSTextField!
    /// Held so switching polishing off can grey it out without a rebuild, which
    /// would take the dictionary table's selection with it.
    private var repairToggle: NSButton?

    /// Indices into `entries` for the rows on screen, so a row number can be
    /// turned back into the entry it edits.
    private var visible: [Int] {
        entries.indices.filter { entries[$0].kind == showing }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The file is editable by hand, and `--polish` in a terminal writes it
        // too, so re-read rather than trusting what was loaded at build time.
        entries = CustomDictionary.load()
        table?.reloadData()
        updateEmpty()
    }

    override func build() {
        entries = CustomDictionary.load()

        buildPolish()
        stack.addArrangedSubview(separator())
        buildDictionary()
    }

    // -----------------------------------------------------------------------
    // Polish
    // -----------------------------------------------------------------------

    private func buildPolish() {
        stack.addArrangedSubview(heading("AI polish"))

        let reason = Polisher.unavailableReason
        let toggle = NSButton(checkboxWithTitle: "Polish transcripts with Apple Intelligence",
                              target: self, action: #selector(togglePolish))
        toggle.state = Settings.polishEnabled ? .on : .off
        toggle.isEnabled = reason == nil
        stack.addArrangedSubview(toggle)

        if let reason {
            stack.addArrangedSubview(caption(reason))
        } else {
            stack.addArrangedSubview(caption(
                "Punctuation, filler words, false starts and paragraphs. Runs on this Mac, "
                + "so nothing is sent anywhere, and adds about a second before pasting. If "
                + "it fails, the transcript is pasted unchanged."))
        }

        let repair = NSButton(checkboxWithTitle: "Also remove self-corrections",
                              target: self, action: #selector(toggleRepair))
        repair.state = Settings.repairEnabled ? .on : .off
        repair.isEnabled = reason == nil && Settings.polishEnabled
        repairToggle = repair
        stack.addArrangedSubview(repair)
        stack.addArrangedSubview(caption(
            "Deletes a phrase you started, broke off and said again: \"send me the doc the "
            + "spreadsheet\" becomes \"send me the spreadsheet\". Only sentences that look "
            + "like this are sent, so most dictations are not slowed at all. It does not "
            + "catch a restart that repeats a word from your first try."))

        let notes = NSTextField(string: Settings.polishInstructions)
        notes.placeholderString = "for example: prefer short sentences"
        notes.target = self
        notes.action = #selector(commitNotes)
        notes.delegate = self
        notes.identifier = NSUserInterfaceItemIdentifier("notes")
        notes.translatesAutoresizingMaskIntoConstraints = false
        notes.widthAnchor.constraint(equalToConstant: 470).isActive = true
        notes.isEnabled = reason == nil
        stack.addArrangedSubview(row([NSTextField(labelWithString: "Style notes")]))
        stack.addArrangedSubview(notes)
        stack.addArrangedSubview(caption(
            "Optional. Shapes how the result reads. It cannot add content or override the "
            + "rules above."))
    }

    @objc private func togglePolish(_ sender: NSButton) {
        Settings.polishEnabled = sender.state == .on
        // Updated in place rather than through `rebuild()`: rebuilding here
        // would also rebuild the dictionary table underneath and drop whatever
        // row was selected.
        repairToggle?.isEnabled = sender.state == .on
    }

    @objc private func toggleRepair(_ sender: NSButton) {
        Settings.repairEnabled = sender.state == .on
    }

    @objc private func commitNotes(_ sender: NSTextField) {
        Settings.polishInstructions = sender.stringValue
    }

    // -----------------------------------------------------------------------
    // Dictionary
    // -----------------------------------------------------------------------

    private func buildDictionary() {
        stack.addArrangedSubview(heading("Dictionary"))
        stack.addArrangedSubview(caption(
            "Terms are words Speak should know. Anything you dictate that sounds like one, "
            + "and is not a word in its own right, is corrected to it. Corrections are "
            + "exact replacements, for mishearings that sound nothing like the word you "
            + "meant."))

        let picker = NSSegmentedControl(
            labels: ["Terms", "Corrections"], trackingMode: .selectOne,
            target: self, action: #selector(switchKind))
        picker.selectedSegment = showing == .term ? 0 : 1
        stack.addArrangedSubview(picker)

        table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.allowsMultipleSelection = false

        for (id, title, width) in columns() {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            // Pinned, or the table redistributes the width it was given and
            // squeezes the last column until its header renders as "...".
            column.minWidth = width
            table.addTableColumn(column)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 470).isActive = true
        // Sized so the whole pane fits without the pane itself scrolling. A
        // scroll view inside a scroll view means the wheel moves the table
        // instead of the page, and the buttons underneath become awkward to
        // reach. The table scrolls internally for long lists.
        scroll.heightAnchor.constraint(equalToConstant: 118).isActive = true
        stack.addArrangedSubview(scroll)

        empty = caption("")
        stack.addArrangedSubview(empty)
        updateEmpty()

        stack.addArrangedSubview(row([
            NSButton(title: "Add", target: self, action: #selector(addEntry)),
            NSButton(title: "Remove", target: self, action: #selector(removeEntry)),
            NSButton(title: "Import…", target: self, action: #selector(importEntries)),
            NSButton(title: "Export…", target: self, action: #selector(exportEntries)),
            NSButton(title: "Reveal file", target: self, action: #selector(reveal)),
        ]))
        stack.addArrangedSubview(caption(
            showing == .term
                ? "Matched by sound. A single word needs five letters and is never swapped "
                    + "for a real English word, so \"Codex\" leaves \"codes\" alone. A "
                    + "phrase needs every word to match, which is how \"Claude Code\" "
                    + "catches \"Cloud coat\"."
                : "Matches whole words where the text is a word, so \"cat\" leaves "
                    + "\"category\" alone. The longest match wins."))
    }

    private func columns() -> [(String, String, CGFloat)] {
        showing == .term
            ? [("text", "Term", 380), ("enabled", "On", 40)]
            : [("text", "Replace", 145), ("replacement", "With", 140),
               ("caseSensitive", "Match case", 85), ("enabled", "On", 45)]
    }

    private func updateEmpty() {
        let none = visible.isEmpty
        empty?.stringValue = showing == .term
            ? "No terms yet. Add names, jargon or product names that come out misspelled."
            : "No corrections yet. Add one for anything you have to fix by hand every time."
        empty?.isHidden = !none
    }

    @objc private func switchKind(_ sender: NSSegmentedControl) {
        showing = sender.selectedSegment == 0 ? .term : .correction
        // Rebuilt rather than reloaded: the columns and the explanation beneath
        // the table are different for the two kinds.
        rebuild()
    }

    @objc private func addEntry() {
        entries.append(CustomDictionary.Entry(kind: showing, text: ""))
        CustomDictionary.save(entries)
        table.reloadData()
        updateEmpty()
        let row = visible.count - 1
        guard row >= 0 else { return }
        table.scrollRowToVisible(row)
        table.selectRowIndexes([row], byExtendingSelection: false)
        // Straight into editing: an empty row is not self-explanatory, and a
        // blank entry left behind does nothing at all.
        table.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func removeEntry() {
        let row = table.selectedRow
        guard row >= 0, row < visible.count else { NSSound.beep(); return }
        entries.remove(at: visible[row])
        CustomDictionary.save(entries)
        table.reloadData()
        updateEmpty()
    }

    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([CustomDictionary.file])
    }

    /// Merge a file in rather than replacing what is here.
    ///
    /// Replacing would be one misclick away from destroying a list somebody
    /// built up over months, and merging is what importing usually means. Both
    /// kinds arrive at once whatever the table is showing, since a file holds
    /// terms and corrections together.
    @objc private func importEntries() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Import terms and corrections. Existing entries are kept."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let data = try? Data(contentsOf: url),
              let incoming = CustomDictionary.decode(data) else {
            report("Nothing imported",
                   "\(url.lastPathComponent) is not a dictionary file that Speak "
                   + "understands. It reads its own exports and TypeWhisper's.",
                   style: .warning)
            return
        }

        let result = CustomDictionary.merge(incoming, into: entries)
        entries.append(contentsOf: result.added)
        CustomDictionary.save(entries)
        rebuild()

        let terms = result.added.filter { $0.kind == .term }.count
        let corrections = result.added.count - terms
        var detail = "\(count(terms, "term")) and \(count(corrections, "correction"))."
        if result.duplicates > 0 {
            detail += " Skipped \(count(result.duplicates, "entry", plural: "entries")) "
                + "already in the dictionary."
        }
        report(result.added.isEmpty ? "Nothing new to import" : "Imported", detail)
    }

    @objc private func exportEntries() {
        guard let data = CustomDictionary.encode(entries) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "speak-dictionary.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? noun : plural ?? noun + "s")"
    }

    private func report(_ message: String, _ detail: String,
                        style: NSAlert.Style = .informational) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.alertStyle = style
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // -----------------------------------------------------------------------
    // Table
    // -----------------------------------------------------------------------

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let rows = visible
        guard row < rows.count, let id = column?.identifier.rawValue else { return nil }
        let entry = entries[rows[row]]
        let cell = NSTableCellView()

        let control: NSView
        switch id {
        case "enabled", "caseSensitive":
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleFlag))
            box.state = (id == "enabled" ? entry.enabled : entry.caseSensitive) ? .on : .off
            box.tag = row
            box.identifier = .init(id)
            control = box
        default:
            let field = NSTextField(string: id == "text" ? entry.text : entry.replacement)
            field.isBordered = false
            field.drawsBackground = false
            field.font = .systemFont(ofSize: 12)
            field.delegate = self
            field.tag = row
            field.identifier = .init(id)
            control = field
        }

        cell.addSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            control.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor,
                                              constant: -4),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func toggleFlag(_ sender: NSButton) {
        let rows = visible
        guard sender.tag < rows.count else { return }
        let index = rows[sender.tag]
        if sender.identifier?.rawValue == "enabled" {
            entries[index].enabled = sender.state == .on
        } else {
            entries[index].caseSensitive = sender.state == .on
        }
        CustomDictionary.save(entries)
    }

    /// Commit on focus loss as well as on Return.
    ///
    /// Without this, typing a term and clicking straight back to the menu bar
    /// to try it would throw the term away, which reads as the feature being
    /// broken rather than as an uncommitted edit.
    func controlTextDidEndEditing(_ n: Notification) {
        guard let field = n.object as? NSTextField,
              let id = field.identifier?.rawValue else { return }

        if id == "notes" {
            Settings.polishInstructions = field.stringValue
            return
        }

        let rows = visible
        guard field.tag < rows.count else { return }
        let index = rows[field.tag]
        if id == "text" {
            entries[index].text = field.stringValue
        } else {
            entries[index].replacement = field.stringValue
        }
        CustomDictionary.save(entries)
    }
}
