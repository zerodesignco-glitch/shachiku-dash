import XCTest
@testable import CopyfitCore
@testable import CopyfitMac

/// OS標準OCR/CoreTextの実機テスト。結果はOS/revisionで変わり得るため、決定ルールテストとは分ける。
/// macOS以外ではadapterがunavailableを返すことだけを確認する。
final class PlatformAdapterTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    #if canImport(Vision)
    func testVisionReadsSyntheticHeadline() throws {
        let url = Self.fixtures.appendingPathComponent("demo12/images/en-US/iphone-6.9/01.png")
        let facts = try ImageInspector.inspect(data: Data(contentsOf: url), fileExtension: "png")
        let ocr = VisionOCR()
        let langs = try XCTUnwrap(ocr.supportedLanguages())
        XCTAssertTrue(langs.contains("en-US"), "\(langs)")
        let obs = try ocr.recognize(imageURL: url, facts: facts, languages: ["en-US"])
        let joined = obs.map(\.text).joined(separator: " ")
        print("VISION_OBS \(obs.map { "\($0.text) \($0.boundingBox) \($0.confidence)" })")
        XCTAssertTrue(joined.localizedCaseInsensitiveContains("commute"), joined)
        // 見出しは画像上部（y < 600）にある＝座標変換が上下反転していない
        let hit = try XCTUnwrap(obs.first { $0.text.localizedCaseInsensitiveContains("commute") })
        XCTAssertLessThan(hit.boundingBox.maxY, 600)
        XCTAssertGreaterThan(hit.boundingBox.minY, 100)
    }

    func testImageIODecodeCheck() throws {
        let check = try XCTUnwrap(PlatformAdapters.decodeCheck())
        XCTAssertNil(check(Self.fixtures.appendingPathComponent("cases/normal-pass/images/en-US/iphone-6.9/01.png")))
    }
    #endif

    #if canImport(CoreText) && canImport(CoreGraphics)
    func testCoreTextBoundaryAndMissingFont() {
        let m = CoreTextMeasurer()
        let meta = LayoutMetadata(fontPostScriptName: "Helvetica-Bold", fontSizePx: 96, lineHeightPx: 120,
                                  trackingPx: 0, alignment: "left", maxLines: 2)
        guard case .measured(let one)? = Optional(m.measure(text: "Hello", metadata: meta,
                                                            rect: PixelRect(x: 0, y: 0, width: 2000, height: 300), locale: "en-US")) else {
            return XCTFail("Helvetica-Boldが計測できません")
        }
        XCTAssertEqual(one.lines, ["Hello"])
        XCTAssertTrue(one.allGlyphsPlaced)
        // CoreTextは送り幅（advance）で折り返すため、境界はink幅ではなく探索で求める。
        func lines(_ w: Double) -> LayoutMeasurement? {
            if case .measured(let r) = m.measure(text: "Hello", metadata: meta,
                                                 rect: PixelRect(x: 0, y: 0, width: w, height: 300), locale: "en-US") { return r }
            return nil
        }
        var lo = 1.0, hi = 2000.0
        while hi - lo > 1 {
            let mid = ((lo + hi) / 2).rounded(.down)
            if (lines(mid)?.lines.count ?? 99) == 1 { hi = mid } else { lo = mid }
        }
        guard let fit = lines(hi) else { return XCTFail("計測できません") }
        XCTAssertEqual(fit.lines.count, 1)
        XCTAssertEqual(PixelRect(x: 0, y: 0, width: hi, height: 300).overflow(of: fit.inkBounds), 0, "1行に収まる最小幅ではinkもbox内")
        XCTAssertGreaterThan(lines(hi - 1)?.lines.count ?? 0, 1, "1px狭めると折り返す")
        XCTAssertLessThanOrEqual(one.inkBounds.maxX, hi, "ink幅は送り幅以下")
        if case .measured(let tight) = m.measure(text: "Hello world again", metadata: meta,
                                                 rect: PixelRect(x: 0, y: 0, width: 300, height: 120), locale: "en-US") {
            XCTAssertFalse(tight.allGlyphsPlaced)
            XCTAssertGreaterThan(tight.lines.count, 1)
        } else { XCTFail() }
        var missing = meta
        missing.fontPostScriptName = "NoSuchFont-Regular-XYZ"
        XCTAssertEqual(m.measure(text: "x", metadata: missing, rect: PixelRect(x: 0, y: 0, width: 100, height: 100), locale: "en-US"),
                       .fontMissing("NoSuchFont-Regular-XYZ"))
    }
    #else
    func testAdaptersUnavailableOffMac() {
        XCTAssertNil(PlatformAdapters.ocr().supportedLanguages())
        let meta = LayoutMetadata(fontPostScriptName: "X", fontSizePx: 10, lineHeightPx: 12, trackingPx: 0, alignment: "left", maxLines: nil)
        if case .unavailable = PlatformAdapters.measurer().measure(text: "x", metadata: meta, rect: PixelRect(x: 0, y: 0, width: 1, height: 1), locale: "en-US") {
        } else { XCTFail() }
    }
    #endif
}
