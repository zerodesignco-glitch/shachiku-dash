import Foundation

public enum ReportWriter {
    static let marker = ".copyfit-report"

    public static func jsonData(_ report: AuditReport) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try enc.encode(report)
        data.append(0x0A)
        return data
    }

    /// 専用出力directoryにだけ書く。既存の非空directoryはcopyfitが作ったもの（marker有り）以外拒否する。
    public static func prepareOutputDirectory(_ out: URL, protectedInputs: [URL]) throws {
        let fm = FileManager.default
        let outReal = out.standardizedFileURL.resolvingSymlinksInPath()
        for input in protectedInputs {
            let inReal = input.standardizedFileURL.resolvingSymlinksInPath()
            if PathGuard.isInside(inReal, outReal) {
                throw CopyfitError.invalidInput("出力先 \(out.path) の中に入力ファイル \(input.path) があります。別のdirectoryを指定してください")
            }
        }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: out.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw CopyfitError.invalidInput("出力先がファイルです: \(out.path)") }
            let contents = (try? fm.contentsOfDirectory(atPath: out.path)) ?? []
            if !contents.isEmpty && !contents.contains(marker) {
                throw CopyfitError.invalidInput("出力先 \(out.path) は空ではなく、copyfitの出力directoryでもありません。上書きを避けるため中断します")
            }
            for name in ["report.json", "index.html", "images"] {
                let p = out.appendingPathComponent(name)
                if fm.fileExists(atPath: p.path) { try fm.removeItem(at: p) }
            }
        } else {
            do { try fm.createDirectory(at: out, withIntermediateDirectories: true) } catch {
                throw CopyfitError.io("出力先を作成できません: \(out.path)")
            }
        }
        try Data("copyfit report directory\n".utf8).write(to: out.appendingPathComponent(marker))
    }

    /// report.json / index.html / images/ を書き出す。画像はhash名でコピーし、入力は変更しない。
    public static func write(_ result: Auditor.Result, to out: URL) throws {
        var report = result.report
        let images = out.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        for (i, url) in result.imageURLs {
            guard i < report.assets.count, let facts = report.assets[i].facts else { continue }
            let ext = facts.format == .jpeg ? "jpg" : facts.format == .png ? "png" : "bin"
            let name = "images/\(facts.fileHash.prefix(24)).\(ext)"
            let dest = out.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.copyItem(at: url, to: dest)
            }
            report.assets[i].reportImagePath = facts.integrityProblem == nil ? name : nil
        }
        try jsonData(report).write(to: out.appendingPathComponent("report.json"))
        try Data(HTMLRenderer.render(report).utf8).write(to: out.appendingPathComponent("index.html"))
    }
}

/// 外部font/CDN/script/telemetryなしの単一HTML。すべての文言・ファイル名をescapeする。
public enum HTMLRenderer {
    public static func escape(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.count)
        for c in s.unicodeScalars {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&#39;"
            default: o.unicodeScalars.append(c)
            }
        }
        return o
    }

    static func badge(_ s: Status) -> String {
        let (icon, label) : (String, String) = {
            switch s {
            case .pass: return ("✓", "PASS")
            case .warn: return ("▲", "WARN")
            case .unknown: return ("?", "UNKNOWN")
            case .fail: return ("✖", "FAIL")
            }
        }()
        return "<span class=\"badge s-\(label.lowercased())\"><span aria-hidden=\"true\">\(icon)</span> \(label)</span>"
    }

    static func basisLabel(_ b: RuleBasis) -> String {
        switch b {
        case .appleOfficial: return "Apple公式要件"
        case .projectRule: return "プロジェクト規則"
        case .heuristic: return "heuristic（推定）"
        case .toolMeta: return "ツール/ruleset"
        }
    }

    static func anchor(_ k: AssetKey) -> String {
        "asset-" + SHA256.hex(Data(k.description.utf8)).prefix(12)
    }

    static func pct(_ v: Double, _ total: Int) -> String {
        String(format: "%.4f%%", total > 0 ? v / Double(total) * 100 : 0)
    }

    public static func render(_ r: AuditReport) -> String {
        var h = ""
        h += """
        <!doctype html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self'; style-src 'unsafe-inline'">
        <meta name="referrer" content="no-referrer">
        <title>Copyfit監査レポート</title>
        <style>\(css)</style>
        </head>
        <body>
        <a class="skip" href="#main">本文へ移動</a>
        <main id="main">
        <h1>Copyfit監査レポート</h1>
        <p class="disclaimer">\(escape(r.disclaimer))</p>

        """
        // summary
        let s = r.summary
        h += """
        <section aria-labelledby="h-summary">
        <h2 id="h-summary">概要</h2>
        <table class="summary">
        <caption>判定の件数（PASSは検査を実施して問題がなかった項目のみ）</caption>
        <thead><tr><th scope="col">状態</th><th scope="col">件数</th><th scope="col">意味</th></tr></thead>
        <tbody>
        <tr><td>\(badge(.fail))</td><td>\(s.fail)</td><td>確定した不備。提出前に修正が必要</td></tr>
        <tr><td>\(badge(.warn))</td><td>\(s.warn)</td><td>不備の疑い（OCR/推定を含む）。目視確認が必要</td></tr>
        <tr><td>\(badge(.unknown))</td><td>\(s.unknown)</td><td>情報不足などで検査できなかった項目。PASSではありません</td></tr>
        <tr><td>\(badge(.pass))</td><td>\(s.pass)</td><td>検査して問題が見つからなかった項目</td></tr>
        </tbody>
        </table>
        <dl class="meta">
        <dt>画像</dt><dd>manifest記載 \(s.assetsDeclared)件 / 検査 \(s.assetsInspected)件</dd>
        <dt>ruleset</dt><dd>\(escape(r.rulesetVersion))\(r.rulesetCheckedAt.map { "（確認日 " + escape($0) + "）" } ?? "")</dd>
        <dt>OCR</dt><dd>\(escape(r.ocrEngine))</dd>
        <dt>文字fit計測</dt><dd>\(escape(r.textMeasurer))</dd>
        <dt>tool</dt><dd>copyfit \(escape(r.toolVersion)) / report schema \(r.schemaVersion)</dd>
        <dt>OS</dt><dd>\(escape(r.osVersion))</dd>
        <dt>生成日時</dt><dd>\(escape(r.generatedAt))</dd>
        </dl>
        </section>

        """

        // matrix
        let keys = r.assets.map(\.key)
        let locales = orderedUnique(keys.map(\.locale) + r.findings.compactMap { $0.assetKey?.locale }.filter { $0 != "*" })
        let targets = orderedUnique(keys.map(\.target) + r.findings.compactMap { $0.assetKey?.target }.filter { $0 != "*" })
        let slots = orderedUnique(keys.map(\.slot) + r.findings.compactMap { $0.assetKey?.slot }.filter { $0 != "*" }).sorted()
        func worst(_ k: AssetKey) -> Status? {
            r.findings.filter { $0.assetKey == k }.map(\.status).max()
        }
        h += """
        <section aria-labelledby="h-matrix">
        <h2 id="h-matrix">locale / target別一覧</h2>
        <div class="scroll"><table>
        <caption>各セルはその画像で最も重い判定。リンクで詳細へ移動</caption>
        <thead><tr><th scope="col">locale</th><th scope="col">target</th>\(slots.map { "<th scope=\"col\">slot " + escape($0) + "</th>" }.joined())</tr></thead>
        <tbody>

        """
        for l in locales.sorted() {
            for t in targets.sorted() {
                h += "<tr><th scope=\"row\">\(escape(l))</th><td>\(escape(t))</td>"
                for sl in slots {
                    let k = AssetKey(locale: l, target: t, slot: sl)
                    if let st = worst(k) {
                        let link = keys.contains(k) ? "<a href=\"#\(anchor(k))\">\(badge(st))</a>" : badge(st)
                        h += "<td>\(link)</td>"
                    } else {
                        h += "<td><span class=\"muted\">—</span></td>"
                    }
                }
                h += "</tr>\n"
            }
        }
        h += "</tbody></table></div>\n</section>\n\n"

        // global findings
        let assetKeys = Set(keys)
        let global = r.findings.filter { f in f.assetKey.map { !assetKeys.contains($0) } ?? true }
        h += "<section aria-labelledby=\"h-global\">\n<h2 id=\"h-global\">全体・欠落・文言表の指摘</h2>\n"
        h += findingsTable(global, caption: "画像に紐づかない指摘（ruleset、欠落画像、文言表）", showAsset: true)
        h += "</section>\n\n"

        // per asset
        h += "<section aria-labelledby=\"h-assets\">\n<h2 id=\"h-assets\">画像別の詳細</h2>\n"
        for a in r.assets.sorted(by: { $0.key < $1.key }) {
            h += assetSection(a, findings: r.findings.filter { $0.assetKey == a.key })
        }
        h += "</section>\n\n"

        h += """
        <section aria-labelledby="h-inputs">
        <h2 id="h-inputs">入力ファイルのSHA-256</h2>
        <div class="scroll"><table><thead><tr><th scope="col">ファイル</th><th scope="col">SHA-256</th></tr></thead><tbody>
        \(r.inputHashes.keys.sorted().map { "<tr><td>\(escape($0))</td><td><code>\(escape(r.inputHashes[$0]!))</code></td></tr>" }.joined(separator: "\n"))
        </tbody></table></div>
        </section>
        </main>
        </body>
        </html>

        """
        return h
    }

    static func orderedUnique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0).inserted }
    }

    static func assetSection(_ a: AssetReportEntry, findings: [Finding]) -> String {
        var h = "<section class=\"asset\" id=\"\(anchor(a.key))\" aria-labelledby=\"\(anchor(a.key))-h\">\n"
        h += "<h3 id=\"\(anchor(a.key))-h\">\(escape(a.key.locale)) / \(escape(a.key.target)) / slot \(escape(a.key.slot))</h3>\n"
        h += "<p class=\"path\">\(escape(a.path))"
        if let f = a.facts {
            h += " — \(f.pixelWidth)×\(f.pixelHeight) \(escape(f.format.rawValue)) \(escape(f.colorDescription))"
        }
        h += "</p>\n<div class=\"asset-body\">\n"
        if let img = a.reportImagePath, let f = a.facts {
            let w = f.pixelWidth, ht = f.pixelHeight
            h += "<figure>\n<a class=\"frame-link\" href=\"\(escape(img))\" aria-label=\"\(escape(a.key.description)) を原寸で開く\">"
            h += "<div class=\"frame\" style=\"aspect-ratio: \(w) / \(ht)\">"
            h += "<img src=\"\(escape(img))\" alt=\"\(escape(a.key.description)) のスクリーンショット\">"
            for fr in a.forbiddenRects {
                h += overlay(fr.rectPx, w, ht, cls: "ov-forbidden", label: "禁止領域 \(fr.id)")
            }
            for rg in a.regions {
                h += overlay(rg.rect, w, ht, cls: "ov-region", label: "テキストbox \(rg.id)")
                if let ink = rg.measuredInkBounds { h += overlay(ink, w, ht, cls: "ov-ink", label: "計測ink \(rg.id)") }
            }
            for o in a.ocrObservations {
                h += overlay(o.boundingBox, w, ht, cls: "ov-ocr", label: "OCR「\(o.text)」")
            }
            h += "</div></a>\n<figcaption><ul class=\"legend\">"
            h += "<li><span class=\"sw ov-region\"></span>テキストbox（破線）</li>"
            h += "<li><span class=\"sw ov-forbidden\"></span>禁止領域（斜線）</li>"
            h += "<li><span class=\"sw ov-ocr\"></span>OCR文字領域（細線）</li>"
            h += "<li><span class=\"sw ov-ink\"></span>計測ink範囲（点線）</li>"
            h += "</ul>クリックで原寸画像を開きます。</figcaption>\n</figure>\n"
        } else {
            h += "<p class=\"noimg\">画像を表示できません（欠落または破損）。</p>\n"
        }
        h += "<div class=\"asset-side\">\n"
        let counts = Status.allCases.reversed().map { st in "\(badge(st)) \(findings.filter { $0.status == st }.count)" }
        h += "<p class=\"counts\">\(counts.joined(separator: " "))</p>\n"
        if let note = a.ocrNote { h += "<p class=\"note\">\(escape(note))</p>\n" }
        if !a.regions.isEmpty {
            h += "<details><summary>期待文言（\(a.regions.count)領域）</summary><dl class=\"copy\">"
            for rg in a.regions {
                h += "<dt>\(escape(rg.id)) \(escape(rg.rect.description))</dt><dd><pre>\(escape(rg.expectedCopy ?? "（なし）"))</pre></dd>"
            }
            h += "</dl></details>\n"
        }
        h += "</div>\n</div>\n"
        let open = findings.filter { $0.status != .pass }
        let passed = findings.filter { $0.status == .pass }
        h += findingsTable(open, caption: "要確認の指摘（\(open.count)件）", showAsset: false)
        if !passed.isEmpty {
            h += "<details><summary>PASSした検査（\(passed.count)件）</summary>\n"
            h += findingsTable(passed, caption: "PASS", showAsset: false)
            h += "</details>\n"
        }
        h += "</section>\n"
        return h
    }

    static func overlay(_ r: PixelRect, _ w: Int, _ h: Int, cls: String, label: String) -> String {
        "<span class=\"ov \(cls)\" title=\"\(escape(label))\" style=\"left:\(pct(r.x, w));top:\(pct(r.y, h));width:\(pct(r.width, w));height:\(pct(r.height, h))\"></span>"
    }

    static func findingsTable(_ fs: [Finding], caption: String, showAsset: Bool) -> String {
        if fs.isEmpty { return "<p class=\"muted\">\(escape(caption)): なし</p>\n" }
        var h = "<div class=\"scroll\"><table class=\"findings\">\n<caption>\(escape(caption))</caption>\n<thead><tr>"
        h += "<th scope=\"col\">状態</th><th scope=\"col\">ルール</th><th scope=\"col\">根拠</th>"
        if showAsset { h += "<th scope=\"col\">対象</th>" }
        h += "<th scope=\"col\">領域</th><th scope=\"col\">内容</th><th scope=\"col\">根拠データ</th><th scope=\"col\">修正案</th></tr></thead>\n<tbody>\n"
        for f in fs {
            h += "<tr><td>\(badge(f.status))</td><td><code>\(escape(f.ruleID))</code> v\(f.ruleVersion)</td><td>\(escape(basisLabel(f.basis)))</td>"
            if showAsset { h += "<td>\(escape(f.assetKey?.description ?? "全体"))</td>" }
            h += "<td>\(escape(f.regionID ?? "—"))</td><td>\(escape(f.message))"
            if let m = f.measuredValue { h += "<br><small>実測: \(escape(m))</small>" }
            if let e = f.expectedValue { h += "<br><small>期待: \(escape(e))</small>" }
            h += "</td><td>"
            if !f.evidence.isEmpty { h += "<ul>" + f.evidence.map { "<li>\(escape($0))</li>" }.joined() + "</ul>" }
            h += "</td><td>\(escape(f.remediation ?? ""))</td></tr>\n"
        }
        h += "</tbody></table></div>\n"
        return h
    }

    static let css = """
    :root{--bg:#ffffff;--fg:#1b1b1f;--muted:#5c5f66;--line:#c9ccd3;--card:#f5f6f8;--link:#0b57d0;
    --pass:#1e6b34;--warn:#8a5300;--unknown:#4b4f58;--fail:#b3261e;--region:#0b57d0;--forbidden:#b3261e;--ocr:#1e6b34;--ink:#a14d00;color-scheme:light dark}
    @media (prefers-color-scheme: dark){:root{--bg:#121316;--fg:#e8e9ec;--muted:#a7abb3;--line:#3a3d44;--card:#1d1f23;--link:#8ab4f8;
    --pass:#7fd18b;--warn:#f2b45a;--unknown:#c3c7cf;--fail:#ff8a80;--region:#8ab4f8;--forbidden:#ff8a80;--ocr:#7fd18b;--ink:#ffb870}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Hiragino Sans","Noto Sans JP",system-ui,sans-serif}
    main{max-width:1200px;margin:0 auto;padding:16px}
    a{color:var(--link)} a:focus-visible,summary:focus-visible{outline:3px solid var(--link);outline-offset:2px}
    .skip{position:absolute;left:-9999px}.skip:focus{left:16px;top:8px;background:var(--bg);padding:4px 8px}
    h1{font-size:1.6rem}h2{font-size:1.3rem;border-bottom:1px solid var(--line);padding-bottom:4px;margin-top:2rem}h3{font-size:1.1rem}
    .disclaimer{background:var(--card);border-left:4px solid var(--warn);padding:8px 12px}
    table{border-collapse:collapse;width:100%;margin:8px 0}
    .findings td:nth-child(2){white-space:nowrap}
    .findings td{overflow-wrap:anywhere}th,td{border:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top}
    caption{text-align:left;color:var(--muted);padding:4px 0}
    .scroll{overflow-x:auto}
    .badge{display:inline-block;font-weight:700;white-space:nowrap;border:1.5px solid currentColor;border-radius:4px;padding:0 6px;font-size:.85rem}
    .s-pass{color:var(--pass)}.s-warn{color:var(--warn)}.s-unknown{color:var(--unknown);border-style:dashed}.s-fail{color:var(--fail)}
    .muted{color:var(--muted)} .meta{display:grid;grid-template-columns:max-content 1fr;gap:4px 16px}.meta dt{font-weight:700}.meta dd{margin:0;overflow-wrap:anywhere}
    .asset{border:1px solid var(--line);border-radius:8px;padding:12px;margin:16px 0;background:var(--card)}
    .asset-body{display:grid;grid-template-columns:minmax(120px,240px) minmax(0,1fr);gap:16px;margin-bottom:8px}
    @media (max-width:560px){.asset-body{grid-template-columns:minmax(0,1fr)}figure{max-width:240px}}
    .counts .badge{margin-right:2px}
    figure{margin:0}.frame{position:relative;width:100%;border:1px solid var(--line);background:repeating-conic-gradient(#8883 0 25%,#0000 0 50%) 0 0/16px 16px}
    .frame img{display:block;width:100%;height:100%}
    .ov{position:absolute;pointer-events:none}
    .ov-region{border:2px dashed var(--region)}
    .ov-forbidden{border:2px solid var(--forbidden);background:repeating-linear-gradient(45deg,color-mix(in srgb,var(--forbidden) 35%,transparent) 0 4px,transparent 4px 10px)}
    .ov-ocr{border:1px solid var(--ocr)}
    .ov-ink{border:2px dotted var(--ink)}
    .legend{list-style:none;padding:0;margin:4px 0;font-size:.85rem}.legend li{display:flex;align-items:center;gap:6px}
    .sw{display:inline-block;width:18px;height:12px;position:static}
    .path{color:var(--muted);word-break:break-all;margin-top:0}
    .note{border-left:4px solid var(--unknown);padding-left:8px}
    pre{white-space:pre-wrap;margin:0;font:inherit}
    details{margin:8px 0}summary{cursor:pointer}
    code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9em;word-break:break-all}
    """
}
