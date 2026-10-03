import Foundation

public struct CopyEntry: Codable, Equatable, Sendable {
    public var locale: String
    public var key: String
    public var text: String
    /// 入力内での位置（CSVは2始まりの行番号、JSONはentries index）。
    public var origin: String

    public init(locale: String, key: String, text: String, origin: String) {
        self.locale = locale
        self.key = key
        self.text = text
        self.origin = origin
    }
}

/// 文言表。重複・空文字はロード時に捨てず、COPY001の判定材料として保持する。
public struct CopyTable: Equatable, Sendable {
    public var entries: [CopyEntry]

    public init(entries: [CopyEntry]) { self.entries = entries }

    public func entries(locale: String, key: String) -> [CopyEntry] {
        entries.filter { $0.locale == locale && $0.key == key }
    }

    /// 一意かつ空でない場合のみ文言を返す。
    public func text(locale: String, key: String) -> String? {
        let found = entries(locale: locale, key: key)
        guard found.count == 1, !found[0].text.isEmpty else { return nil }
        return found[0].text
    }
}

public enum CopyLoader {
    public static func load(data: Data, fileExtension: String) throws -> CopyTable {
        switch fileExtension.lowercased() {
        case "csv": return try loadCSV(data)
        case "json": return try loadJSON(data)
        default: throw CopyfitError.invalidInput("文言ファイルは .csv または .json です（\(fileExtension)）")
        }
    }

    private struct JSONCopy: Decodable {
        var schemaVersion: Int
        var entries: [Entry]
        struct Entry: Decodable { var locale: String; var key: String; var text: String }
    }

    static func loadJSON(_ data: Data) throws -> CopyTable {
        let decoded: JSONCopy
        do { decoded = try JSONDecoder().decode(JSONCopy.self, from: data) } catch {
            throw CopyfitError.invalidInput("文言JSONを読めません（{schemaVersion:1, entries:[{locale,key,text}]}）: \(error)")
        }
        guard decoded.schemaVersion == 1 else {
            throw CopyfitError.invalidInput("文言JSONの未対応schemaVersion: \(decoded.schemaVersion)")
        }
        return CopyTable(entries: decoded.entries.enumerated().map { i, e in
            CopyEntry(locale: e.locale, key: e.key, text: normalizeNewlines(e.text), origin: "entries[\(i)]")
        })
    }

    /// RFC 4180互換: 引用符内のカンマ/改行/""を扱う。文字列`\n`は改行に変換しない。
    static func loadCSV(_ data: Data) throws -> CopyTable {
        guard var text = String(data: data, encoding: .utf8) else {
            throw CopyfitError.invalidInput("文言CSVがUTF-8ではありません")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let rows = try parseCSV(text)
        guard let header = rows.first else { throw CopyfitError.invalidInput("文言CSVが空です") }
        guard header.fields.map({ $0.trimmingCharacters(in: .whitespaces) }) == ["locale", "key", "text"] else {
            throw CopyfitError.invalidInput("文言CSVのヘッダは `locale,key,text` の3列です（実際: \(header.fields.joined(separator: ","))）")
        }
        var entries: [CopyEntry] = []
        for row in rows.dropFirst() {
            if row.fields == [""] { continue }  // 空行
            guard row.fields.count == 3 else {
                throw CopyfitError.invalidInput("文言CSV \(row.line)行目: 列数が3ではありません（\(row.fields.count)列）。カンマを含む文言は\"\"で囲んでください")
            }
            entries.append(CopyEntry(locale: row.fields[0], key: row.fields[1],
                                     text: normalizeNewlines(row.fields[2]), origin: "line \(row.line)"))
        }
        return CopyTable(entries: entries)
    }

    /// CRLF/CRは意味を変えずにLFへ揃える（改行そのものは保持）。
    static func normalizeNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    struct Row: Equatable { var fields: [String]; var line: Int }

    static func parseCSV(_ text: String) throws -> [Row] {
        var rows: [Row] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var fieldWasQuoted = false
        var line = 1
        var rowStartLine = 1
        var chars = Array(text.unicodeScalars)[...]

        func endField() {
            fields.append(field)
            field = ""
            fieldWasQuoted = false
        }
        func endRow() {
            endField()
            rows.append(Row(fields: fields, line: rowStartLine))
            fields = []
        }

        while let c = chars.popFirst() {
            if inQuotes {
                if c == "\"" {
                    if chars.first == "\"" { chars.removeFirst(); field.unicodeScalars.append("\"") }
                    else { inQuotes = false }
                } else {
                    if c == "\n" { line += 1 }
                    field.unicodeScalars.append(c)
                }
                continue
            }
            switch c {
            case "\"":
                if field.isEmpty && !fieldWasQuoted { inQuotes = true; fieldWasQuoted = true }
                else { throw CopyfitError.invalidInput("文言CSV \(line)行目: 引用符の位置が不正です（フィールド途中の\"は\"\"と書きます）") }
            case ",":
                endField()
            case "\r":
                if chars.first == "\n" { chars.removeFirst() }
                endRow(); line += 1; rowStartLine = line
            case "\n":
                endRow(); line += 1; rowStartLine = line
            default:
                if fieldWasQuoted {
                    throw CopyfitError.invalidInput("文言CSV \(line)行目: 閉じ引用符の後に文字があります")
                }
                field.unicodeScalars.append(c)
            }
        }
        if inQuotes { throw CopyfitError.invalidInput("文言CSV: 引用符が閉じられていません（\(rowStartLine)行目から）") }
        if !field.isEmpty || !fields.isEmpty || fieldWasQuoted { endRow() }
        return rows
    }
}
