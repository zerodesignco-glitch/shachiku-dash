import XCTest
@testable import CopyfitCore

final class ImageInspectorTests: XCTestCase {
    func load(_ rel: String) throws -> Data {
        try Data(contentsOf: TestPaths.fixtures.appendingPathComponent(rel))
    }

    func testNormalPNG() throws {
        let f = try ImageInspector.inspect(data: load("cases/normal-pass/images/en-US/iphone-6.9/01.png"), fileExtension: "png")
        XCTAssertEqual(f.pixelWidth, 1290)
        XCTAssertEqual(f.pixelHeight, 2796)
        XCTAssertEqual(f.format, .png)
        XCTAssertFalse(f.hasAlphaChannel)
        XCTAssertNil(f.integrityProblem)
        XCTAssertFalse(f.extensionMismatch)
        XCTAssertEqual(f.fileHash.count, 64)
    }

    func testAlphaPNG() throws {
        let f = try ImageInspector.inspect(data: load("cases/alpha-png/images/en-US/iphone-6.9/01.png"), fileExtension: "png")
        XCTAssertTrue(f.hasAlphaChannel)
        XCTAssertTrue(f.colorDescription.hasPrefix("RGBA"))
    }

    func testCorruptPNGIsReportedNotThrown() throws {
        let f = try ImageInspector.inspect(data: load("cases/corrupt-png/images/en-US/iphone-6.9/01.png"), fileExtension: "png")
        XCTAssertNotNil(f.integrityProblem)
    }

    func testHugeImageRejectedByHeader() throws {
        XCTAssertThrowsError(try ImageInspector.inspect(data: load("cases/huge-image/images/en-US/iphone-6.9/01.png"), fileExtension: "png")) { e in
            guard case CopyfitError.limitExceeded = e else { return XCTFail("\(e)") }
        }
    }

    func testFileSizeLimit() {
        var limits = Limits()
        limits.maxFileBytes = 10
        XCTAssertThrowsError(try ImageInspector.inspect(data: Data(count: 11), fileExtension: "png", limits: limits))
    }

    func testJPEGWithExifOrientationIsNormalized() throws {
        let f = try ImageInspector.inspect(data: load("cases/jpeg-exif-rotated/images/en-US/iphone-6.9/01.jpg"), fileExtension: "jpg")
        XCTAssertEqual(f.format, .jpeg)
        XCTAssertEqual(f.orientation, 6)
        XCTAssertEqual(f.pixelWidth, 1290)
        XCTAssertEqual(f.pixelHeight, 2796)
        XCTAssertNil(f.integrityProblem)
    }

    func testExtensionMismatch() throws {
        let f = try ImageInspector.inspect(data: load("cases/ext-mismatch/images/en-US/iphone-6.9/01.jpg"), fileExtension: "jpg")
        XCTAssertEqual(f.format, .png)
        XCTAssertTrue(f.extensionMismatch)
    }

    func testUnknownFormat() throws {
        let f = try ImageInspector.inspect(data: Data("GIF89a....".utf8), fileExtension: "gif")
        XCTAssertEqual(f.format, .unknown)
        XCTAssertNotNil(f.integrityProblem)
    }

    func testTruncatedJPEG() throws {
        let data = try load("cases/jpeg-exif-rotated/images/en-US/iphone-6.9/01.jpg")
        let f = try ImageInspector.inspect(data: data.prefix(data.count - 100), fileExtension: "jpg")
        XCTAssertNotNil(f.integrityProblem)
    }
}

final class CopyTableTests: XCTestCase {
    func csv(_ s: String) throws -> CopyTable { try CopyLoader.load(data: Data(s.utf8), fileExtension: "csv") }

    func testQuotedFieldsAndRealNewlines() throws {
        let t = try csv("locale,key,text\r\nja-JP,a,\"一行目\r\n二行目\"\nen-US,b,\"He said \"\"hi\"\", ok\"\n")
        XCTAssertEqual(t.text(locale: "ja-JP", key: "a"), "一行目\n二行目")
        XCTAssertEqual(t.text(locale: "en-US", key: "b"), "He said \"hi\", ok")
    }

    func testLiteralBackslashNIsNotConverted() throws {
        let t = try csv("locale,key,text\nen-US,a,Line\\nStill one line\n")
        XCTAssertEqual(t.text(locale: "en-US", key: "a"), "Line\\nStill one line")
    }

    func testBOMAndEmptyAndDuplicatesAreKept() throws {
        let t = try csv("\u{FEFF}locale,key,text\nen-US,a,\nen-US,b,x\nen-US,b,y\n")
        XCTAssertEqual(t.entries.count, 3)
        XCTAssertNil(t.text(locale: "en-US", key: "a"))
        XCTAssertNil(t.text(locale: "en-US", key: "b"))
    }

    func testBadHeaderAndColumnsAndQuotes() {
        XCTAssertThrowsError(try csv("lang,key,text\n"))
        XCTAssertThrowsError(try csv("locale,key,text\nen-US,a,b,c\n"))
        XCTAssertThrowsError(try csv("locale,key,text\nen-US,a,\"open\n"))
        XCTAssertThrowsError(try csv("locale,key,text\nen-US,a,x\"y\n"))
    }

    func testJSONFormat() throws {
        let json = #"{"schemaVersion":1,"entries":[{"locale":"de-DE","key":"k","text":"Zeile\r\nzwei"}]}"#
        let t = try CopyLoader.load(data: Data(json.utf8), fileExtension: "json")
        XCTAssertEqual(t.text(locale: "de-DE", key: "k"), "Zeile\nzwei")
    }

    func testNonUTF8Rejected() {
        XCTAssertThrowsError(try CopyLoader.load(data: Data([0x6c, 0xff, 0xfe]), fileExtension: "csv"))
    }
}

final class ManifestTests: XCTestCase {
    func load(_ s: String) throws -> Manifest { try ManifestLoader.load(data: Data(s.utf8)) }

    let base = """
    {"schemaVersion":1,"ruleset":"x","requiredLocales":["en-US"],"requiredTargets":["t"],"requiredSlots":["01"],
     "assets":[{"locale":"en-US","target":"t","slot":"01","path":"a.png","textRegions":[%REGIONS%],"forbiddenRectsPx":[%FORBIDDEN%]}]}
    """

    func m(regions: String = "", forbidden: String = "") -> String {
        base.replacingOccurrences(of: "%REGIONS%", with: regions).replacingOccurrences(of: "%FORBIDDEN%", with: forbidden)
    }

    func testForbiddenRectBothForms() throws {
        let x = try load(m(forbidden: #"[1,2,3,4], {"id":"notch","rectPx":[5,6,7,8],"note":"mockup"}"#))
        let f = x.assets[0].forbiddenRectsPx!
        XCTAssertEqual(f[0].rectPx, PixelRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(f[1].id, "notch")
        XCTAssertEqual(f[1].note, "mockup")
    }

    func testNegativeRectRejected() {
        XCTAssertThrowsError(try load(m(regions: #"{"id":"h","copyKey":"k","rectPx":[-1,0,10,10]}"#)))
        XCTAssertThrowsError(try load(m(regions: #"{"id":"h","copyKey":"k","rectPx":[0,0,0,10]}"#)))
        XCTAssertThrowsError(try load(m(regions: #"{"id":"h","copyKey":"k","rectPx":[0,0,10]}"#)))
    }

    func testDuplicateRegionIDRejected() {
        let r = #"{"id":"h","copyKey":"k","rectPx":[0,0,10,10]}"#
        XCTAssertThrowsError(try load(m(regions: r + "," + r)))
    }

    func testPlaceholderFontMeansNoMetadata() throws {
        let x = try load(m(regions: #"{"id":"h","copyKey":"k","rectPx":[0,0,10,10],"fontPostScriptName":"REPLACE_WITH_INSTALLED_FONT","fontSizePx":80,"lineHeightPx":96}"#))
        XCTAssertNil(x.assets[0].textRegions![0].layoutMetadata)
    }

    func testUnsupportedSchemaAndMissingField() {
        XCTAssertThrowsError(try load(m().replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")))
        XCTAssertThrowsError(try load(#"{"schemaVersion":1}"#)) { e in
            XCTAssertTrue("\(e)".contains("必須項目"), "\(e)")
        }
    }

    func testBreakAllowlistNeedsReasonAndDate() {
        let bad = m().replacingOccurrences(of: "\"assets\"", with: #""breakAllowlist":[{"locale":"en-US","target":"t","slot":"01","regionID":"h","ruleID":"BREAK001","reason":"","expires":"2027-01-01"}],"assets""#)
        XCTAssertThrowsError(try load(bad))
    }
}

final class GeometryAndPathTests: XCTestCase {
    func testVisionConversionTopLeftOrigin() {
        // Visionの左下原点: 画像下端から10%の位置、高さ20% → 左上原点ではy = 70%
        let r = CoordinateConversion.visionNormalizedToPixel(x: 0.1, y: 0.1, width: 0.5, height: 0.2, imageWidth: 1000, imageHeight: 2000)
        XCTAssertEqual(r, PixelRect(x: 100, y: 1400, width: 500, height: 400))
        let back = CoordinateConversion.pixelToVisionNormalized(r, imageWidth: 1000, imageHeight: 2000)
        XCTAssertEqual(back.y, 0.1, accuracy: 1e-9)
        XCTAssertEqual(back.height, 0.2, accuracy: 1e-9)
    }

    func testOrientedSize() {
        XCTAssertTrue(CoordinateConversion.orientedSize(width: 2796, height: 1290, exifOrientation: 6) == (1290, 2796))
        XCTAssertTrue(CoordinateConversion.orientedSize(width: 2796, height: 1290, exifOrientation: 3) == (2796, 1290))
    }

    func testRectHelpers() {
        let box = PixelRect(x: 0, y: 0, width: 100, height: 50)
        XCTAssertEqual(box.overflow(of: PixelRect(x: 10, y: 10, width: 91, height: 10)), 1)
        XCTAssertEqual(box.overflow(of: PixelRect(x: 10, y: 10, width: 89, height: 10)), 0)
        XCTAssertFalse(box.isValid(inWidth: 99, height: 50))
    }

    func testPathGuard() throws {
        let root = tempDir()
        let outside = tempDir()
        try Data("x".utf8).write(to: outside.appendingPathComponent("secret.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.png"),
                                                   withDestinationURL: outside.appendingPathComponent("secret.png"))
        let g = PathGuard(root: root)
        XCTAssertNoThrow(try g.resolve("images/a.png"))
        XCTAssertThrowsError(try g.resolve("../a.png"))
        XCTAssertThrowsError(try g.resolve("images/../../a.png"))
        XCTAssertThrowsError(try g.resolve("/etc/passwd"))
        XCTAssertThrowsError(try g.resolve("link.png"))
    }

    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(Data(repeating: 0x61, count: 1000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }
}
