import Foundation

/// Reads a collection export from whiskystats.com (Collection → Export, an .xlsx with one row per bottle: WBID, Name,
/// Bottle Count, Currency, Purchase Price, Purchase Date, …) or the same columns saved as CSV, into Cask bottles.
/// Columns are found by their header, so their order does not matter. Rows with the same WBID are merged (counts
/// added, the price averaged per bottle). A purchase price is only kept when it is in euros, as Cask counts in euros.
enum CaskImport {
    enum Failure: LocalizedError {
        case unreadable(String), noHeader, noRows
        var errorDescription: String? {
            switch self {
            case .unreadable(let s): return "Could not read the file: \(s)"
            case .noHeader: return "No WBID column found: this does not look like a Whiskystats collection export."
            case .noRows: return "The export has no bottles with a Whiskybase ID."
            }
        }
    }

    struct Result { var bottles: [CaskBottle]; var total: Int; var skipped: Int }

    static func read(_ url: URL) throws -> Result {
        let rows: [[String]]
        switch url.pathExtension.lowercased() {
        case "xlsx": rows = try xlsxRows(url)
        case "csv", "txt": rows = csvRows(try String(contentsOf: url, encoding: .utf8))
        default: throw Failure.unreadable("only .xlsx and .csv are supported")
        }
        return try bottles(from: rows)
    }

    /// Header row first; matching is case-insensitive and ignores spaces, so "Bottle Count" and "bottle_count" both work.
    static func bottles(from rows: [[String]]) throws -> Result {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        guard let hi = rows.firstIndex(where: { $0.contains { norm($0) == "wbid" } }) else { throw Failure.noHeader }
        let header = rows[hi].map(norm)
        func col(_ names: String...) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        let cID = col("wbid")!, cName = col("name"), cCount = col("bottlecount", "quantity", "count")
        let cCur = col("currency"), cPrice = col("purchaseprice"), cDate = col("purchasedate")
        var order: [String] = [], merged: [String: CaskBottle] = [:], paid: [String: (sum: Double, n: Int)] = [:]
        var total = 0, skipped = 0
        for r in rows[(hi + 1)...] {
            func cell(_ i: Int?) -> String { i.flatMap { $0 < r.count ? r[$0].trimmingCharacters(in: .whitespacesAndNewlines) : nil } ?? "" }
            let raw = cell(cID)
            if raw.isEmpty { if r.contains(where: { !$0.isEmpty }) { skipped += 1 }; continue }
            guard let id = WhiskyStats.whiskyID(from: raw.hasSuffix(".0") ? String(raw.dropLast(2)) : raw) else { skipped += 1; continue }
            let n = max(1, Int(Double(cell(cCount)) ?? 1))
            total += n
            let cur = cell(cCur).uppercased()
            let price = (cur.isEmpty || cur == "EUR") ? Double(cell(cPrice).replacingOccurrences(of: ",", with: ".")) : nil
            if let price { paid[id, default: (0, 0)].sum += price * Double(n); paid[id, default: (0, 0)].n += n }
            let date = isoDate(cell(cDate))
            if var b = merged[id] {
                b.quantity += n
                if let d = date, b.bought.map({ d < $0 }) ?? true { b.bought = d }
                merged[id] = b
            } else {
                let name = cell(cName)
                merged[id] = CaskBottle(whiskyId: id, name: name.isEmpty ? id : name, quantity: n, bought: date)
                order.append(id)
            }
        }
        guard !order.isEmpty else { throw Failure.noRows }
        let out = order.map { id -> CaskBottle in
            var b = merged[id]!
            if let p = paid[id], p.n > 0 { b.price = (p.sum / Double(p.n) * 100).rounded() / 100 }
            return b
        }
        return Result(bottles: out, total: total, skipped: skipped)
    }

    /// The export's dates are text ("2024-05-07"); a date cell typed by hand in Excel arrives as a serial day number.
    static func isoDate(_ s: String) -> String? {
        if s.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { return String(s.prefix(10)) }
        guard let serial = Double(s), serial > 20000, serial < 80000 else { return nil }
        let d = Date(timeIntervalSince1970: (serial - 25569) * 86400)
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Merging into the current list: a bottle already in it keeps its own id (so nothing on the bar jumps), and
    /// the export decides the rest. Bottles not in the export are left out, as the export is the whole collection.
    static func merge(_ imported: [CaskBottle], into current: [CaskBottle]) -> [CaskBottle] {
        imported.map { b in
            var b = b
            if let old = current.first(where: { $0.whiskyId == b.whiskyId }) { b.id = old.id }
            return b
        }
    }

    // MARK: CSV

    static func csvRows(_ text: String) -> [[String]] {
        let firstLine = text.prefix { $0 != "\n" }
        let sep: Character = firstLine.filter { $0 == ";" }.count > firstLine.filter { $0 == "," }.count ? ";" : ","
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = text.makeIterator()
        while let ch = it.next() {
            if quoted {
                if ch == "\"" { quoted = false } else { field.append(ch) }
            } else if ch == "\"" {
                if field.hasSuffix("\"") || !field.isEmpty { field.append("\"") }
                quoted = true
            } else if ch == sep { row.append(field); field = "" }
            else if ch == "\n" || ch == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
            else if ch != "\r" { field.append(ch) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: XLSX (a zip of XML parts; macOS's own unzip reads them, no library needed)

    static func xlsxRows(_ url: URL) throws -> [[String]] {
        let shared = (try? unzip(url, "xl/sharedStrings.xml")).map(SharedStrings.parse) ?? []
        let sheet = try unzip(url, firstSheetPath(url))
        return SheetRows.parse(sheet, shared: shared)
    }

    /// The first sheet in workbook order, via the workbook's relationships; sheet1.xml when those cannot be read.
    private static func firstSheetPath(_ url: URL) -> String {
        guard let wb = try? unzip(url, "xl/workbook.xml"), let rels = try? unzip(url, "xl/_rels/workbook.xml.rels"),
              let rid = firstMatch(#"<sheet\b[^>]*\br:id="([^"]+)""#, in: wb),
              let target = firstMatch(#"<Relationship\b[^>]*\bId="\#(NSRegularExpression.escapedPattern(for: rid))"[^>]*\bTarget="([^"]+)""#, in: rels)
                ?? firstMatch(#"<Relationship\b[^>]*\bTarget="([^"]+)"[^>]*\bId="\#(NSRegularExpression.escapedPattern(for: rid))""#, in: rels)
        else { return "xl/worksheets/sheet1.xml" }
        return target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
    }

    private static func firstMatch(_ pattern: String, in data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8), let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func unzip(_ url: URL, _ member: String) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path, member]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw Failure.unreadable(error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { throw Failure.unreadable("\(member) is missing; is this an Excel (.xlsx) file?") }
        return data
    }

    private final class SharedStrings: NSObject, XMLParserDelegate {
        var out: [String] = [], cur = "", inT = false
        static func parse(_ d: Data) -> [String] { let s = SharedStrings(); let p = XMLParser(data: d); p.delegate = s; p.parse(); return s.out }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if e == "si" { cur = "" } else if e == "t" { inT = true }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inT { cur += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "t" { inT = false } else if e == "si" { out.append(cur) }
        }
    }

    private final class SheetRows: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: [[String]] = [], row: [String] = [], type: String?, col = 0, text = "", inValue = false
        init(shared: [String]) { self.shared = shared }
        static func parse(_ d: Data, shared: [String]) -> [[String]] { let s = SheetRows(shared: shared); let p = XMLParser(data: d); p.delegate = s; p.parse(); return s.rows }
        /// "C12" → 2 (zero-based column), so empty cells that Excel leaves out keep the columns in place.
        static func column(_ ref: String) -> Int { ref.prefix { $0.isLetter }.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1 }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch e {
            case "row": row = []
            case "c": type = a["t"]; col = a["r"].map(Self.column) ?? row.count; text = ""
            case "v", "t": inValue = true
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inValue { text += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            switch e {
            case "v", "t": inValue = false
            case "c":
                var v = text
                if type == "s", let i = Int(text), i < shared.count { v = shared[i] }
                while row.count < col { row.append("") }
                if row.count == col { row.append(v) }
            case "row": rows.append(row)
            default: break
            }
        }
    }
}
