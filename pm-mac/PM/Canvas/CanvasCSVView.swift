import AppKit

/// A CSV or TSV card: the rows as a table at reading size, scrolling both ways. Quick Look draws a CSV
/// as a letter-size page of small print, unreadable on a card (2026-11-06), so these get their own.
///
/// - No header row: files often lead with lines that aren't one (an account number, an address).
/// - Columns sized to their longest cell, up to `maxColumnWidth`; the rest truncates with a tooltip.
/// - The first `rowLimit` rows; the last row says how many more there are.
@MainActor
final class CanvasCSVView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    static let rowLimit = 5000
    static let maxColumnWidth: CGFloat = 320
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    private let table = NSTableView()
    private var rows: [[String]] = []

    init(text: String, separator: Character) {
        super.init(frame: .zero)
        var parsed = Self.parse(text, separator: separator)
        let more = parsed.count - Self.rowLimit
        if more > 0 {
            parsed.removeLast(more)
            parsed.append(["\(more) more rows"])
        }
        rows = parsed
        let columns = rows.map(\.count).max() ?? 0
        for index in 0..<columns {
            let column = NSTableColumn(identifier: .init("\(index)"))
            let widest = rows.prefix(500).map { index < $0.count ? Self.width(of: $0[index]) : 0 }.max() ?? 0
            column.width = min(max(widest + 22, 30), Self.maxColumnWidth)
            column.minWidth = 24
            table.addTableColumn(column)
        }
        table.headerView = nil
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.gridColor = .separatorColor
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        documentView = table
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        setAccessibilityLabel("Table, \(rows.count) rows")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, let index = Int(column.identifier.rawValue) else { return nil }
        let cell = NSTextField(labelWithString: "")
        cell.font = Self.font
        cell.lineBreakMode = .byTruncatingTail
        let text = index < rows[row].count ? rows[row][index] : ""
        cell.stringValue = text
        cell.toolTip = Self.width(of: text) + 22 > column.width ? text : nil
        // Numbers line up on the right, as a spreadsheet's do.
        cell.alignment = Self.isNumber(text) ? .right : .left
        return CellPadding(cell)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    private static func isNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "$€£%"))
            .replacingOccurrences(of: ",", with: "")
        return !trimmed.isEmpty && Double(trimmed) != nil
    }

    /// RFC 4180: quoted fields may hold the separator, newlines, and "" for a quote. CRLF or LF.
    static func parse(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, afterQuote = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; afterQuote = true; pending = next }
                    } else { quoted = false }
                } else {
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty && !afterQuote:
                quoted = true
            case separator:
                row.append(field); field = ""; afterQuote = false
            case "\n", "\r\n", "\r":
                row.append(field); field = ""; afterQuote = false
                rows.append(row); row = []
            default:
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

/// A cell's text, inset from the grid lines and centred vertically.
private final class CellPadding: NSView {
    init(_ field: NSTextField) {
        super.init(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
