import XCTest
@testable import CopyfitCore

/// Fixtures/cases/* と Fixtures/demo12 を実ファイルとして通し、expected.jsonと突き合わせる。
/// OCR/CoreTextはOS依存のため、ここでは固定観測（ocr.json）またはunavailableを注入する。
final class FixtureCaseTests: XCTestCase {
    struct Expected: Decodable {
        struct Item: Decodable, Hashable {
            var ruleID: String
            var status: String
            var asset: String?
            var region: String?
        }
        var deterministic: [Item]
        var heuristicMustInclude: [Item]?
        var exitCode: Int?
        var now: String?
        var rulesetFile: String?
    }

    struct OCRFixture: Decodable {
        var text: String
        var boundingBox: [Double]
        var confidence: Double
        var engineRevision: String
    }

    /// 確定的ルール（誤判定0を要求する対象）。BREAK001のUNKNOWN（改行情報なし）は除く。
    static func isDeterministic(_ f: Finding) -> Bool {
        let families = ["ASSET", "IMAGE", "RULE001", "SAFE001", "COPY001", "BREAK001"]
        guard families.contains(where: { f.ruleID.hasPrefix($0) }), f.status != .pass else { return false }
        if f.ruleID == "BREAK001" && f.status == .unknown { return false }
        return true
    }

    func runCase(_ dir: URL) throws -> (result: Result<Auditor.Result, Error>, expected: Expected) {
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: dir.appendingPathComponent("expected.json")))
        var ocr: OCRProvider = UnavailableOCR(reason: "test")
        let ocrURL = dir.appendingPathComponent("ocr.json")
        if FileManager.default.fileExists(atPath: ocrURL.path) {
            let raw = try JSONDecoder().decode([String: [OCRFixture]].self, from: Data(contentsOf: ocrURL))
            ocr = FixedOCR(observations: raw.mapValues { $0.map {
                OCRObservation(text: $0.text, boundingBox: try! PixelRect(array: $0.boundingBox),
                               confidence: $0.confidence, engineRevision: $0.engineRevision)
            } })
        }
        var opts = AuditOptions()
        opts.now = expected.now.map(day) ?? day("2026-10-03")
        if let r = expected.rulesetFile { opts.rulesetURL = dir.appendingPathComponent(r) }
        let auditor = Auditor(ocr: ocr, measurer: UnavailableMeasurer(reason: "test"))
        let result = Result { try auditor.run(manifestURL: dir.appendingPathComponent("manifest.json"),
                                              copyURL: dir.appendingPathComponent("copy.csv"), options: opts) }
        return (result, expected)
    }

    func item(_ f: Finding) -> Expected.Item {
        Expected.Item(ruleID: f.ruleID, status: f.status.rawValue, asset: f.assetKey?.description, region: f.regionID)
    }

    func check(_ dir: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let name = dir.lastPathComponent
        let (result, expected) = try runCase(dir)
        switch result {
        case .failure(let e):
            XCTAssertEqual(expected.exitCode, 2, "\(name): 想定外の入力エラー \(e)", file: file, line: line)
        case .success(let r):
            if let code = expected.exitCode {
                XCTAssertEqual(Int(ExitCode.from(summary: r.report.summary, strict: false).rawValue), code, "\(name) exit code", file: file, line: line)
            }
            // 期待はregion未指定なら任意regionと一致。multisetとして完全一致を要求（見逃し・誤検知の両方を検出）。
            var actual = r.report.findings.filter(Self.isDeterministic).map(item)
            var unmatched: [Expected.Item] = []
            for e in expected.deterministic {
                if let i = actual.firstIndex(where: { $0.ruleID == e.ruleID && $0.status == e.status && $0.asset == e.asset
                    && (e.region == nil || $0.region == e.region) }) {
                    actual.remove(at: i)
                } else {
                    unmatched.append(e)
                }
            }
            XCTAssertTrue(unmatched.isEmpty, "\(name): 見逃し \(unmatched)", file: file, line: line)
            XCTAssertTrue(actual.isEmpty, "\(name): 誤検知 \(actual)", file: file, line: line)
            for h in expected.heuristicMustInclude ?? [] {
                XCTAssertTrue(r.report.findings.map(item).contains { $0.ruleID == h.ruleID && $0.status == h.status
                    && $0.asset == h.asset && (h.region == nil || $0.region == h.region) },
                              "\(name): heuristic期待 \(h) がありません", file: file, line: line)
            }
            // UNKNOWN（検査不能）をPASSにしていない: OCRなしならTEXT001はPASSにならない
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("ocr.json").path) {
                XCTAssertFalse(r.report.findings.contains { $0.ruleID == "TEXT001" && $0.status == .pass }, name)
            }
            XCTAssertFalse(r.report.findings.contains { $0.ruleID == "FIT001" && $0.status == .pass },
                           "\(name): 計測なしでFIT001 PASSはありえない")
        }
    }

    func testAllEdgeCases() throws {
        let cases = TestPaths.fixtures.appendingPathComponent("cases")
        let names = try FileManager.default.contentsOfDirectory(atPath: cases.path).sorted()
        XCTAssertGreaterThanOrEqual(names.count, 25)
        for n in names { try check(cases.appendingPathComponent(n)) }
    }

    func testDemo12() throws {
        try check(TestPaths.fixtures.appendingPathComponent("demo12"))
    }

    func testInputsUnchangedAndReportWritten() throws {
        let dir = TestPaths.fixtures.appendingPathComponent("demo12")
        let (result, _) = try runCase(dir)
        let r = try result.get()
        let out = tempDir().appendingPathComponent("report")
        try ReportWriter.prepareOutputDirectory(out, protectedInputs: Array(r.inputFiles.keys))
        try ReportWriter.write(r, to: out)
        try Auditor.verifyUnchanged(r.inputFiles)
        XCTAssertEqual(r.inputFiles.count, 11 + 2)
        // JSONとHTMLの整合性: JSONを読み戻し、FAIL件数がHTML概要に出ている
        let json = try JSONDecoder().decode(AuditReport.self, from: Data(contentsOf: out.appendingPathComponent("report.json")))
        XCTAssertEqual(json.summary, r.report.summary)
        let html = try String(contentsOf: out.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("<td>\(json.summary.fail)</td>"))
        for a in json.assets where a.reportImagePath != nil {
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent(a.reportImagePath!).path))
            XCTAssertTrue(html.contains(a.reportImagePath!))
        }
        // 再実行（同じ出力先）は許可、copyfit以外の非空directoryは拒否
        XCTAssertNoThrow(try ReportWriter.prepareOutputDirectory(out, protectedInputs: []))
        let foreign = tempDir()
        try Data("x".utf8).write(to: foreign.appendingPathComponent("keep.txt"))
        XCTAssertThrowsError(try ReportWriter.prepareOutputDirectory(foreign, protectedInputs: []))
        // 入力を含むdirectoryへの出力は拒否
        XCTAssertThrowsError(try ReportWriter.prepareOutputDirectory(dir, protectedInputs: Array(r.inputFiles.keys)))
    }

    func testAssetLimit() throws {
        var opts = AuditOptions()
        opts.limits.maxAssets = 3
        let dir = TestPaths.fixtures.appendingPathComponent("demo12")
        XCTAssertThrowsError(try Auditor(ocr: UnavailableOCR(reason: "t"), measurer: UnavailableMeasurer(reason: "t"))
            .run(manifestURL: dir.appendingPathComponent("manifest.json"), copyURL: dir.appendingPathComponent("copy.csv"), options: opts))
    }

    func testHundredImagesNoCrash() throws {
        let src = TestPaths.fixtures.appendingPathComponent("cases/normal-pass/images/en-US/iphone-6.9/01.png")
        let root = tempDir()
        let slots = (1...10).map { String(format: "%02d", $0) }
        let locales = (0..<10).map { "l\($0)-XX" }
        var assets: [[String: Any]] = []
        var csv = "locale,key,text\n"
        for l in locales {
            csv += "\(l),headline,Hello world\n"
            for s in slots {
                let rel = "images/\(l)/\(s).png"
                try FileManager.default.createDirectory(at: root.appendingPathComponent("images/\(l)"), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: src, to: root.appendingPathComponent(rel))
                assets.append(["locale": l, "target": "iphone-6.9", "slot": s, "path": rel, "expectedPixelSize": [1290, 2796],
                               "textRegions": [["id": "headline", "copyKey": "headline", "rectPx": [80, 160, 1130, 300]]]])
            }
        }
        let m: [String: Any] = ["schemaVersion": 1, "ruleset": "apple-screenshots-2026-10-03", "requiredLocales": locales,
                                "requiredTargets": ["iphone-6.9"], "requiredSlots": slots, "assets": assets]
        try JSONSerialization.data(withJSONObject: m).write(to: root.appendingPathComponent("manifest.json"))
        try Data(csv.utf8).write(to: root.appendingPathComponent("copy.csv"))
        var opts = AuditOptions()
        opts.now = day("2026-10-03")
        let start = Date()
        let r = try Auditor(ocr: UnavailableOCR(reason: "t"), measurer: UnavailableMeasurer(reason: "t"))
            .run(manifestURL: root.appendingPathComponent("manifest.json"), copyURL: root.appendingPathComponent("copy.csv"), options: opts)
        print("PERF 100 images (OCR/CoreTextなし) \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        XCTAssertEqual(r.report.summary.assetsInspected, 100)
        XCTAssertEqual(r.report.summary.fail, 0)
    }

    func testDemo12Performance() throws {
        let dir = TestPaths.fixtures.appendingPathComponent("demo12")
        let start = Date()
        _ = try runCase(dir).result.get()
        let elapsed = Date().timeIntervalSince(start)
        print("PERF demo12 (OCR/CoreTextなし) \(String(format: "%.3f", elapsed))s")
        XCTAssertLessThan(elapsed, 30)
    }
}

final class ReportTests: XCTestCase {
    func testHTMLEscapesEverything() throws {
        let dir = TestPaths.fixtures.appendingPathComponent("cases/malicious-strings")
        var opts = AuditOptions()
        opts.now = day("2026-10-03")
        let r = try Auditor(ocr: UnavailableOCR(reason: "<b>x</b>"), measurer: UnavailableMeasurer(reason: "t"))
            .run(manifestURL: dir.appendingPathComponent("manifest.json"), copyURL: dir.appendingPathComponent("copy.csv"), options: opts)
        let html = HTMLRenderer.render(r.report)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<b>x</b>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &quot;quotes&quot;"))
        for pattern in ["src=\"http", "href=\"http", "url(", "<script", "<link", "@import"] {
            XCTAssertFalse(html.contains(pattern), "外部参照/scriptなし: \(pattern)")
        }
        XCTAssertTrue(html.contains("Content-Security-Policy"))
    }

    func testEscapeFunction() {
        XCTAssertEqual(HTMLRenderer.escape("<a href=\"x\" onclick='y'>&</a>"),
                       "&lt;a href=&quot;x&quot; onclick=&#39;y&#39;&gt;&amp;&lt;/a&gt;")
    }

    func testStatusNotColorOnly() {
        for s in Status.allCases {
            XCTAssertTrue(HTMLRenderer.badge(s).contains(s.rawValue))
        }
    }

    /// golden report: 出力schemaとHTMLの意図しない変更を検出する。更新はUPDATE_GOLDEN=1で。
    func testGoldenReport() throws {
        let dir = TestPaths.fixtures.appendingPathComponent("cases/kinsoku-line-start")
        var opts = AuditOptions()
        opts.now = day("2026-10-03")
        opts.osVersionOverride = "golden-os"
        let r = try Auditor(ocr: UnavailableOCR(reason: "golden"), measurer: UnavailableMeasurer(reason: "golden"))
            .run(manifestURL: dir.appendingPathComponent("manifest.json"), copyURL: dir.appendingPathComponent("copy.csv"), options: opts)
        let json = String(decoding: try ReportWriter.jsonData(r.report), as: UTF8.self)
        let html = HTMLRenderer.render(r.report)
        let gj = TestPaths.golden.appendingPathComponent("kinsoku-report.json")
        let gh = TestPaths.golden.appendingPathComponent("kinsoku-index.html")
        if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: TestPaths.golden, withIntermediateDirectories: true)
            try json.write(to: gj, atomically: true, encoding: .utf8)
            try html.write(to: gh, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(json, try String(contentsOf: gj, encoding: .utf8))
        XCTAssertEqual(html, try String(contentsOf: gh, encoding: .utf8))
    }
}
