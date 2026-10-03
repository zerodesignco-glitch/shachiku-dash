import XCTest
@testable import CopyfitCore

final class RuleEngineTests: XCTestCase {
    let now = day("2026-10-03")
    let copy = CopyTable(entries: [CopyEntry(locale: "en-US", key: "headline", text: "Hello world", origin: "t")])

    func run(_ m: Manifest, copy: CopyTable? = nil, facts: AssetFacts = goodFacts,
             ocr: OCROutcome? = nil, measure: MeasureOutcome? = nil) -> [Finding] {
        var measurements: [Int: [String: MeasureOutcome]] = [:]
        if let measure { measurements[0] = ["headline": measure] }
        return RuleEngine.evaluate(RuleInput(
            manifest: m, copy: copy ?? self.copy, ruleset: bundledRuleset(),
            inspections: Dictionary(uniqueKeysWithValues: m.assets.indices.map { ($0, .inspected(facts)) }),
            ocr: ocr.map { [0: $0] } ?? [:], measurements: measurements, now: now))
    }

    func measured(width: Double, lines: [String] = ["Hello world"], placed: Bool = true) -> MeasureOutcome {
        .measured(LayoutMeasurement(lines: lines, allGlyphsPlaced: placed,
                                    inkBounds: PixelRect(x: 80, y: 250, width: width, height: 90)))
    }

    // FIT001: 1px余裕/1px不足の境界
    func testFitBoundaryOnePixel() {
        let m = manifest(assets: [assetSpec()])
        let ok = run(m, measure: measured(width: 1129)).with("FIT001")
        XCTAssertEqual(ok.map(\.status), [.pass])
        let exact = run(m, measure: measured(width: 1130)).with("FIT001")
        XCTAssertEqual(exact.map(\.status), [.pass])
        let over = run(m, measure: measured(width: 1131)).with("FIT001")
        XCTAssertEqual(over.map(\.status), [.fail])
        XCTAssertTrue(over[0].message.contains("1px"))
    }

    func testFitLinesAndGlyphs() {
        let m = manifest(assets: [assetSpec()])
        XCTAssertEqual(run(m, measure: measured(width: 500, lines: ["a", "b", "c"])).with("FIT001").map(\.status), [.fail])
        XCTAssertEqual(run(m, measure: measured(width: 500, placed: false)).with("FIT001").map(\.status), [.fail])
    }

    func testUnverifiedMetadataNeverPasses() {
        let m = manifest(assets: [assetSpec(regions: [region(verified: false)])])
        XCTAssertEqual(run(m, measure: measured(width: 500)).with("FIT001").map(\.status), [.unknown])
        XCTAssertEqual(run(m, measure: measured(width: 2000)).with("FIT001").map(\.status), [.warn])
    }

    func testMissingFontAndMetadataAreUnknown() {
        let m = manifest(assets: [assetSpec()])
        XCTAssertEqual(run(m, measure: .fontMissing("Nope")).with("FIT001").map(\.status), [.unknown])
        XCTAssertEqual(run(m, measure: .unavailable("linux")).with("FIT001").map(\.status), [.unknown])
        let noFont = manifest(assets: [assetSpec(regions: [region(font: nil)])])
        XCTAssertEqual(run(noFont).with("FIT001").map(\.status), [.unknown])
    }

    func testRegionOutsideImageIsUnknownNotPass() {
        let m = manifest(assets: [assetSpec(regions: [region(rect: [1200, 160, 200, 100])])])
        let f = run(m).with("FIT001")
        XCTAssertEqual(f.map(\.status), [.unknown])
    }

    // SAFE001
    func testForbiddenRect() {
        let notch = ForbiddenRect(id: "notch", rectPx: PixelRect(x: 500, y: 200, width: 300, height: 100))
        let verified = manifest(assets: [assetSpec(forbidden: [notch])])
        XCTAssertEqual(run(verified).with("SAFE001").map(\.status), [.fail])
        let unverified = manifest(assets: [assetSpec(regions: [region(verified: false)], forbidden: [notch])])
        XCTAssertEqual(run(unverified).with("SAFE001").map(\.status), [.warn])
        // box自体は禁止領域外だが、計測inkが侵入
        let below = ForbiddenRect(id: "below", rectPx: PixelRect(x: 0, y: 470, width: 1290, height: 50))
        let ink = MeasureOutcome.measured(LayoutMeasurement(lines: ["x"], allGlyphsPlaced: true,
                                                            inkBounds: PixelRect(x: 100, y: 400, width: 100, height: 80)))
        XCTAssertEqual(run(manifest(assets: [assetSpec(forbidden: [below])]), measure: ink).with("SAFE001").map(\.status), [.fail])
    }

    // TEXT001 / FIT002
    func obs(_ text: String, conf: Double = 0.9, rect: PixelRect = PixelRect(x: 300, y: 250, width: 690, height: 100)) -> OCRObservation {
        OCRObservation(text: text, boundingBox: rect, confidence: conf, engineRevision: "test")
    }

    func testOCRMatchMismatchLowConfidenceAndNothingRead() {
        let m = manifest(assets: [assetSpec()])
        XCTAssertEqual(run(m, ocr: .observations([obs("Hello  world")])).with("TEXT001").map(\.status), [.pass])
        XCTAssertEqual(run(m, ocr: .observations([obs("Hello wor")])).with("TEXT001").map(\.status), [.warn])
        XCTAssertEqual(run(m, ocr: .observations([obs("Hello world", conf: 0.2)])).with("TEXT001").map(\.status), [.unknown])
        let none = run(m, ocr: .observations([])).with("TEXT001")
        XCTAssertEqual(none.map(\.status), [.unknown])
        XCTAssertTrue(none[0].message.contains("断定しません"))
        XCTAssertEqual(run(m, ocr: .unsupportedLanguage("xx")).with("TEXT001").map(\.status), [.unknown])
        XCTAssertEqual(run(m).with("TEXT001").map(\.status), [.unknown])
    }

    func testOCRMultiLineOrderAndCJKSpaces() {
        let m = manifest(assets: [assetSpec(locale: "ja-JP")], locales: ["ja-JP"])
        let c = CopyTable(entries: [CopyEntry(locale: "ja-JP", key: "headline", text: "毎日の通勤を、\nもっと速く。", origin: "t")])
        let lines = [obs("もっと 速く。", rect: PixelRect(x: 300, y: 330, width: 600, height: 90)),
                     obs("毎日の通勤を、", rect: PixelRect(x: 300, y: 200, width: 600, height: 90))]
        XCTAssertEqual(run(m, copy: c, ocr: .observations(lines)).with("TEXT001").map(\.status), [.pass])
        // 句読点を削って一致扱いにしない
        let noComma = [obs("毎日の通勤を", rect: PixelRect(x: 300, y: 200, width: 600, height: 90)),
                       obs("もっと速く。", rect: PixelRect(x: 300, y: 330, width: 600, height: 90))]
        XCTAssertEqual(run(m, copy: c, ocr: .observations(noComma)).with("TEXT001").map(\.status), [.warn])
    }

    func testFIT002EdgeAndBoxOverflow() {
        let m = manifest(assets: [assetSpec()])
        let edge = obs("Hello world", rect: PixelRect(x: 100, y: 250, width: 1190, height: 100))
        let f = run(m, ocr: .observations([edge])).with("FIT002")
        XCTAssertEqual(f.count, 2)  // boxはみ出し + 画像端
        XCTAssertTrue(f.allSatisfy { $0.status == .warn })
        // OCR誤差（4px以内）は警告しない
        let slight = obs("Hello world", rect: PixelRect(x: 77, y: 250, width: 600, height: 100))
        XCTAssertTrue(run(m, ocr: .observations([slight])).with("FIT002").isEmpty)
        // 領域外テキストが画像端に接している
        let stray = obs("cut", rect: PixelRect(x: 1200, y: 2000, width: 90, height: 60))
        XCTAssertEqual(run(m, ocr: .observations([stray])).with("FIT002").count, 1)
    }

    // ASSET / IMAGE / RULE
    func testDimensionsAndAlpha() {
        let m = manifest(assets: [assetSpec()])
        var f = goodFacts
        f.pixelWidth = 2796; f.pixelHeight = 1290
        let swapped = run(m, facts: f).with("IMAGE001").filter { $0.status == .fail }
        XCTAssertEqual(swapped.count, 1)  // manifest指定とは不一致、Appleのlandscapeとしては許容
        XCTAssertEqual(swapped[0].message, "縦横が逆です")
        f = goodFacts; f.hasAlphaChannel = true
        XCTAssertEqual(run(m, facts: f).with("IMAGE002").map(\.status), [.fail])
        f = goodFacts; f.integrityProblem = "broken"
        let broken = run(m, facts: f)
        XCTAssertEqual(broken.with("IMAGE003").map(\.status), [.fail])
        XCTAssertTrue(broken.with("FIT001").isEmpty)
    }

    func testRulesetMissingExpiredUnknownTarget() {
        var m = manifest(assets: [assetSpec()])
        m.ruleset = nil
        var input = RuleInput(manifest: m, copy: copy, ruleset: nil, inspections: [0: .inspected(goodFacts)], now: now)
        XCTAssertEqual(RuleEngine.evaluate(input).with("RULE001").map(\.status), [.unknown])
        m.ruleset = "apple-screenshots-2026-10-03"
        input.manifest = m
        input.ruleset = bundledRuleset()
        input.now = day("2027-01-02")  // 91日後
        XCTAssertEqual(RuleEngine.evaluate(input).with("RULE001").map(\.status), [.warn])
        input.now = day("2027-01-01")  // 90日後
        XCTAssertEqual(RuleEngine.evaluate(input).with("RULE001").map(\.status), [.pass])
        let unknownTarget = manifest(assets: [assetSpec(target: "watch")], targets: ["watch"])
        XCTAssertTrue(run(unknownTarget).with("RULE001").contains { $0.status == .unknown && $0.assetKey != nil })
    }

    func testFallbackDuplicateAndMaxSlots() {
        var m = manifest(assets: [assetSpec()], locales: ["en-US", "en-GB"])
        XCTAssertEqual(run(m).with("ASSET001").filter { $0.status == .fail }.count, 1)
        m.fallbacks = [.init(locale: "en-GB", target: "iphone-6.9", slot: "01", useLocale: "en-US", reason: "同一")]
        XCTAssertTrue(run(m).with("ASSET001").allSatisfy { $0.status == .pass })
        let dup = manifest(assets: [assetSpec(), assetSpec()])
        let f = run(dup)
        XCTAssertEqual(f.with("ASSET002").map(\.status), [.fail])
        XCTAssertTrue(f.with("IMAGE001").isEmpty, "重複assetは一方を選んで検査しない")
        let many = manifest(assets: [], slots: (1...11).map { String(format: "%02d", $0) })
        XCTAssertEqual(run(many).with("ASSET003").map(\.status), [.fail])
    }

    func testCopyRules() {
        let m = manifest(assets: [assetSpec(), assetSpec(locale: "de-DE")], locales: ["en-US", "de-DE"])
        let same = CopyTable(entries: [CopyEntry(locale: "en-US", key: "headline", text: "Copyfit", origin: "1"),
                                       CopyEntry(locale: "de-DE", key: "headline", text: "Copyfit", origin: "2")])
        XCTAssertEqual(run(m, copy: same).with("COPY002").map(\.status), [.warn])
        var allowed = m
        allowed.copyAllowlist = [.init(key: "headline", reason: "ブランド名")]
        XCTAssertTrue(run(allowed, copy: same).with("COPY002").isEmpty)
        let dup = CopyTable(entries: same.entries + [CopyEntry(locale: "de-DE", key: "headline", text: "X", origin: "3")])
        XCTAssertEqual(run(m, copy: dup).with("COPY001").map(\.status), [.fail])
    }

    func testBreakAllowlistAndExpiry() {
        var m = manifest(assets: [assetSpec(locale: "ja-JP")], locales: ["ja-JP"])
        let c = CopyTable(entries: [CopyEntry(locale: "ja-JP", key: "headline", text: "記録し\n、振り返る", origin: "t")])
        XCTAssertEqual(run(m, copy: c).with("BREAK001").map(\.status), [.warn])
        m.breakAllowlist = [.init(locale: "ja-JP", target: "iphone-6.9", slot: "01", regionID: "headline",
                                  ruleID: "BREAK001", reason: "デザイン意図", expires: "2026-12-31")]
        XCTAssertEqual(run(m, copy: c).with("BREAK001").map(\.status), [.pass])
        m.breakAllowlist![0].expires = "2026-10-01"
        let expired = run(m, copy: c).with("BREAK001")
        XCTAssertEqual(expired.map(\.status), [.warn])
        XCTAssertTrue(expired[0].message.contains("期限切れ"))
    }

    func testLayoutLinesTakePriorityForBreaks() {
        let m = manifest(assets: [assetSpec(locale: "ja-JP")], locales: ["ja-JP"])
        let c = CopyTable(entries: [CopyEntry(locale: "ja-JP", key: "headline", text: "残業時間を記録", origin: "t")])
        let bad = MeasureOutcome.measured(LayoutMeasurement(lines: ["残業時間を記録し", "た。"], allGlyphsPlaced: true,
                                                            inkBounds: PixelRect(x: 100, y: 200, width: 500, height: 200)))
        let f = run(m, copy: c, measure: bad)
        XCTAssertEqual(f.with("BREAK001").map(\.status), [.pass])
        XCTAssertEqual(f.with("BREAK002").map(\.status), [.warn])
        XCTAssertTrue(f.with("BREAK002")[0].evidence.contains { $0.contains("layoutモデル") })
    }

    func testExitCodes() {
        func s(_ st: [Status]) -> Summary {
            Summary(findings: st.map { Finding(ruleID: "X", basis: .toolMeta, assetKey: nil, status: $0, message: "") },
                    assetsDeclared: 0, assetsInspected: 0)
        }
        XCTAssertEqual(ExitCode.from(summary: s([.pass, .warn, .unknown]), strict: false), .ok)
        XCTAssertEqual(ExitCode.from(summary: s([.pass, .warn]), strict: true), .strictUnresolved)
        XCTAssertEqual(ExitCode.from(summary: s([.unknown]), strict: true), .strictUnresolved)
        XCTAssertEqual(ExitCode.from(summary: s([.fail, .unknown]), strict: true), .fail)
        XCTAssertEqual(ExitCode.from(summary: s([.pass]), strict: true), .ok)
    }

    func testDeterministicOrdering() {
        let m = manifest(assets: [assetSpec(), assetSpec(locale: "de-DE")], locales: ["en-US", "de-DE"])
        XCTAssertEqual(run(m), run(m))
    }
}
