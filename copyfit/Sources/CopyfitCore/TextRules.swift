import Foundation

/// OCR照合用の正規化。NFCと空白の扱いだけを変え、句読点・数字・濁点など意味を変える文字は削らない。
public enum TextNormalizer {
    public static func isCJK(locale: String) -> Bool {
        let lang = locale.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
        return ["ja", "zh", "ko"].contains(lang)
    }

    /// 改行・連続空白は1つの空白へ。CJK localeでは空白自体を意味のない区切りとして除去する。
    public static func normalizeForComparison(_ s: String, locale: String) -> String {
        let nfc = s.precomposedStringWithCanonicalMapping
        var out = ""
        var pendingSpace = false
        for ch in nfc {
            if ch.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace && !isCJK(locale: locale) { out.append(" ") }
            pendingSpace = false
            out.append(ch)
        }
        return out
    }

    /// 期待文言とOCR文字列の差分を人が読める形で返す（共通prefix/suffixを除いた中央部分）。
    public static func diffSummary(expected: String, actual: String) -> String {
        let e = Array(expected), a = Array(actual)
        var p = 0
        while p < e.count && p < a.count && e[p] == a[p] { p += 1 }
        var s = 0
        while s < e.count - p && s < a.count - p && e[e.count - 1 - s] == a[a.count - 1 - s] { s += 1 }
        let em = String(e[p..<(e.count - s)]), am = String(a[p..<(a.count - s)])
        return "位置\(p): 期待「\(em)」 / OCR「\(am)」"
    }
}

/// 改行の品質検査（BREAK001: 禁則・禁止語分断 / BREAK002: 孤立行・数字+単位分断）。
/// 全Unicodeの完全実装ではなく、ja/en/deの初期セット。
public enum LineBreakRules {
    /// 行頭禁則（行頭に来てはいけない文字）。JIS X 4051の主要部分。
    public static let noLineStart: Set<Character> = Set(
        "、。，．・：；？！゛゜ヽヾゝゞ々〻ー‐–〜～）］｝〕〉》」』】〙〗〟’”｠»" +
        "ぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿ" +
        ",.:;!?)]}%‰℃％…‥"
    )
    /// 行末禁則（行末に来てはいけない文字）。
    public static let noLineEnd: Set<Character> = Set("（［｛〔〈《「『【〘〖〝‘“｟«([{¥$€£＄￥#＃")

    /// 数字の直後で行を分けてはいけない単位（先頭一致）。
    public static let units = ["%", "％", "円", "個", "件", "人", "回", "倍", "年", "月", "日", "時間", "時", "分", "秒",
                               "kg", "g", "km", "m", "cm", "mm", "GB", "MB", "KB", "TB", "fps", "Hz", "px", "pt",
                               "min", "h", "x", "×", "€", "Std", "Min"]

    public struct Violation: Equatable, Sendable {
        public var ruleID: String
        public var lineIndex: Int
        public var detail: String
        public var heuristic: Bool
    }

    /// `lines`は改行済みの行（期待文言の明示改行、またはlayout/OCR由来）。
    public static func check(lines rawLines: [String], locale: String,
                             noBreakPhrases: [String] = [],
                             orphanCheck: Bool = true,
                             orphanMaxGraphemesCJK: Int = 2) -> [Violation] {
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2 else { return [] }
        var out: [Violation] = []
        let cjk = TextNormalizer.isCJK(locale: locale)

        for i in 1..<lines.count {
            let prev = lines[i - 1], cur = lines[i]
            if let f = cur.first, noLineStart.contains(f), cjk || ",.:;!?)]}%".contains(f) {
                out.append(Violation(ruleID: "BREAK001", lineIndex: i,
                                     detail: "\(i + 1)行目が行頭禁則文字「\(f)」で始まっています", heuristic: false))
            }
            if let l = prev.last, noLineEnd.contains(l) {
                out.append(Violation(ruleID: "BREAK001", lineIndex: i - 1,
                                     detail: "\(i)行目が行末禁則文字「\(l)」で終わっています", heuristic: false))
            }
            // 指定禁止語の分断: 行の境界をまたいで出現する場合のみ。
            // 結合後にだけ現れる＝境界をまたいでいる。
            let joinedBoundary = cjk ? prev + cur : prev + " " + cur
            for phrase in noBreakPhrases where !phrase.isEmpty
                && joinedBoundary.contains(phrase) && !prev.contains(phrase) && !cur.contains(phrase) {
                out.append(Violation(ruleID: "BREAK001", lineIndex: i - 1,
                                     detail: "分断禁止語「\(phrase)」が\(i)〜\(i + 1)行目で分断されています", heuristic: false))
            }
            // 数字+単位の分断。
            if let l = prev.last, l.isNumber,
               let unit = units.filter({ cur.hasPrefix($0) }).max(by: { $0.count < $1.count }) {
                // 英独では "5 min" のような通常の語間改行も分断として扱う。単位が後続語の一部（例: "make"のm）なら除外。
                let rest = cur.dropFirst(unit.count)
                if rest.isEmpty || !(rest.first!.isLetter && !cjk) {
                    out.append(Violation(ruleID: "BREAK002", lineIndex: i - 1,
                                         detail: "数字と単位「\(l)|\(unit)」が\(i)〜\(i + 1)行目で分断されています", heuristic: true))
                }
            }
        }
        if orphanCheck, let last = lines.last {
            if cjk {
                let n = last.filter { !$0.isWhitespace && !noLineStart.contains($0) }.count
                if n <= orphanMaxGraphemesCJK {
                    out.append(Violation(ruleID: "BREAK002", lineIndex: lines.count - 1,
                                         detail: "最終行が\(last.count)文字だけの孤立行です「\(last)」", heuristic: true))
                }
            } else {
                // 1語だけ、かつ直前行の25%未満の長さのときだけ孤立行とみなす（2行見出しの通常の折返しを除外）。
                let words = last.split(whereSeparator: { $0.isWhitespace })
                let prevLen = lines[lines.count - 2].count
                if words.count == 1, Double(last.count) < Double(prevLen) * 0.25 {
                    out.append(Violation(ruleID: "BREAK002", lineIndex: lines.count - 1,
                                         detail: "最終行が1語だけの孤立行です「\(last)」", heuristic: true))
                }
            }
        }
        return out
    }
}
