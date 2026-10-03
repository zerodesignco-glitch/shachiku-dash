import XCTest
@testable import CopyfitCore

/// ビルド済み `copyfit` バイナリを実行し、終了コードと出力を確認する。
final class CLITests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    var binary: URL {
        #if os(macOS)
        for b in Bundle.allBundles where b.bundlePath.hasSuffix(".xctest") {
            return b.bundleURL.deletingLastPathComponent().appendingPathComponent("copyfit")
        }
        fatalError("products directory not found")
        #else
        return Bundle.main.bundleURL.appendingPathComponent("copyfit")
        #endif
    }

    @discardableResult
    func run(_ args: [String]) throws -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    func audit(_ caseDir: String, extra: [String] = []) throws -> (code: Int32, out: String, err: String) {
        let dir = Self.fixtures.appendingPathComponent(caseDir)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("copyfit-cli-\(UUID().uuidString)")
        return try run(["audit", "--manifest", dir.appendingPathComponent("manifest.json").path,
                        "--copy", dir.appendingPathComponent("copy.csv").path, "--out", out.path,
                        "--now", "2026-10-03", "--no-ocr"] + extra)
    }

    func testExitCodes() throws {
        // 0: FAILなし（OCR無効なのでUNKNOWNは残る）
        let ok = try audit("cases/normal-pass")
        XCTAssertEqual(ok.code, 0, ok.out + ok.err)
        XCTAssertTrue(ok.out.contains("提出成功の保証ではありません"))
        // 3: strictではUNKNOWNが残ると失敗
        XCTAssertEqual(try audit("cases/normal-pass", extra: ["--strict"]).code, 3)
        // 1: FAIL
        XCTAssertEqual(try audit("cases/alpha-png").code, 1)
        XCTAssertEqual(try audit("cases/alpha-png", extra: ["--strict"]).code, 1)
        // 2: 入力エラー
        let traversal = try audit("cases/path-traversal")
        XCTAssertEqual(traversal.code, 2)
        XCTAssertTrue(traversal.err.contains("パス安全性エラー"), traversal.err)
        XCTAssertEqual(try audit("cases/huge-image").code, 2)
        XCTAssertEqual(try run(["audit", "--manifest", "x"]).code, 2)
        XCTAssertEqual(try run(["audit", "--bogus"]).code, 2)
        XCTAssertEqual(try run(["nope"]).code, 2)
    }

    func testJSONSummaryAndRulesetsCommand() throws {
        let r = try audit("demo12", extra: ["--json"])
        XCTAssertEqual(r.code, 1)
        let obj = try JSONSerialization.jsonObject(with: Data(r.out.utf8)) as! [String: Any]
        XCTAssertEqual(obj["exitCode"] as? Int, 1)
        XCTAssertEqual(obj["assetsDeclared"] as? Int, 11)
        let rs = try run(["rulesets"])
        XCTAssertTrue(rs.out.contains("apple-screenshots-2026-10-03"))
        XCTAssertEqual(try run(["--version"]).out, "copyfit \(copyfitToolVersion)\n")
    }
}
