import CopyfitCore
import CopyfitMac
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

let usage = """
使い方:
  copyfit audit --manifest <manifest.json> --copy <copy.csv|copy.json> --out <report-dir> [options]
  copyfit rulesets            同梱rulesetの一覧
  copyfit --version

options:
  --strict           未確認のWARN/UNKNOWNが残る場合に終了コード3（CI推奨）
  --no-ocr           OCRを実行しない（TEXT001はUNKNOWN）
  --ruleset <file>   確認済みrulesetファイルを明示指定（同梱より優先）
  --now <YYYY-MM-DD> 基準日を固定（再現テスト用。ruleset期限やallowlist期限に影響）
  --json             要約をJSONで標準出力へ出す
  --no-color         色を使わない（環境変数NO_COLORでも可）

終了コード: 0=FAILなし（提出保証ではありません） 1=FAILあり 2=入力/実行エラー 3=--strictで未確認WARN/UNKNOWNあり
"""

struct CLIError: Error { let message: String }

func parseArgs(_ args: [String]) throws -> [String: String] {
    var out: [String: String] = [:]
    var i = 0
    let flags: Set<String> = ["--strict", "--no-ocr", "--json", "--no-color", "--help", "-h"]
    let valued: Set<String> = ["--manifest", "--copy", "--out", "--ruleset", "--now"]
    while i < args.count {
        let a = args[i]
        if flags.contains(a) { out[a] = "1"; i += 1; continue }
        if valued.contains(a) {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw CLIError(message: "\(a) に値が必要です") }
            out[a] = args[i + 1]
            i += 2
            continue
        }
        throw CLIError(message: "不明な引数です: \(a)")
    }
    return out
}

func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
}

func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func runAudit(_ opts: [String: String]) -> Int32 {
    let useColor = opts["--no-color"] == nil && ProcessInfo.processInfo.environment["NO_COLOR"] == nil && isatty(1) != 0
    func color(_ s: Status) -> String {
        guard useColor else { return s.rawValue }
        let code = s == .fail ? "31" : s == .warn ? "33" : s == .unknown ? "35" : "32"
        return "\u{1B}[\(code)m\(s.rawValue)\u{1B}[0m"
    }
    guard let m = opts["--manifest"], let c = opts["--copy"], let o = opts["--out"] else {
        eprint("エラー: --manifest, --copy, --out は必須です\n\n" + usage)
        return ExitCode.inputError.rawValue
    }
    var options = AuditOptions()
    options.ocrEnabled = opts["--no-ocr"] == nil
    if let r = opts["--ruleset"] { options.rulesetURL = fileURL(r) }
    if let n = opts["--now"] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: n) else {
            eprint("エラー: --now はYYYY-MM-DDです: \(n)")
            return ExitCode.inputError.rawValue
        }
        options.now = d
    }
    let manifestURL = fileURL(m), copyURL = fileURL(c), outURL = fileURL(o)
    let auditor = Auditor(ocr: PlatformAdapters.ocr(), measurer: PlatformAdapters.measurer(),
                          decodeCheck: PlatformAdapters.decodeCheck())
    let started = Date()
    do {
        try ReportWriter.prepareOutputDirectory(outURL, protectedInputs: [manifestURL, copyURL])
        let result = try auditor.run(manifestURL: manifestURL, copyURL: copyURL, options: options)
        try ReportWriter.prepareOutputDirectory(outURL, protectedInputs: Array(result.inputFiles.keys))
        try ReportWriter.write(result, to: outURL)
        try Auditor.verifyUnchanged(result.inputFiles)

        let s = result.report.summary
        let code = ExitCode.from(summary: s, strict: opts["--strict"] != nil)
        if opts["--json"] != nil {
            let summary: [String: Any] = [
                "fail": s.fail, "warn": s.warn, "unknown": s.unknown, "pass": s.pass,
                "assetsDeclared": s.assetsDeclared, "assetsInspected": s.assetsInspected,
                "exitCode": Int(code.rawValue),
                "report": outURL.appendingPathComponent("report.json").path,
            ]
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("copyfit \(copyfitToolVersion) / ruleset \(result.report.rulesetVersion)")
            print("OCR: \(result.report.ocrEngine)")
            print("fit計測: \(result.report.textMeasurer)")
            print("画像: \(s.assetsInspected)/\(s.assetsDeclared)件を検査（\(String(format: "%.1f", Date().timeIntervalSince(started)))秒）")
            print("\(color(.fail)) \(s.fail)  \(color(.warn)) \(s.warn)  \(color(.unknown)) \(s.unknown)  \(color(.pass)) \(s.pass)")
            for f in result.report.findings where f.status == .fail {
                print("  \(color(.fail)) \(f.ruleID) \(f.assetKey?.description ?? "全体")\(f.regionID.map { " [\($0)]" } ?? ""): \(f.message)")
            }
            if s.unknown > 0 { print("※UNKNOWNは検査できなかった項目です（問題なしではありません）") }
            print("report: \(outURL.appendingPathComponent("index.html").path)")
            switch code {
            case .ok: print("終了コード0: FAILはありません（提出成功の保証ではありません）")
            case .fail: print("終了コード1: FAILがあります")
            case .strictUnresolved: print("終了コード3: --strictで未確認のWARN/UNKNOWNが残っています")
            case .inputError: break
            }
        }
        return code.rawValue
    } catch let e as CopyfitError {
        eprint("エラー: \(e)")
        return ExitCode.inputError.rawValue
    } catch {
        eprint("エラー: \(error)")
        return ExitCode.inputError.rawValue
    }
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "--help"
switch command {
case "--version":
    print("copyfit \(copyfitToolVersion)")
    exit(0)
case "rulesets":
    for id in RulesetLoader.bundledIDs() { print(id) }
    exit(0)
case "audit":
    args.removeFirst()
    do {
        let opts = try parseArgs(args)
        if opts["--help"] != nil || opts["-h"] != nil { print(usage); exit(0) }
        exit(runAudit(opts))
    } catch let e as CLIError {
        eprint("エラー: \(e.message)\n\n" + usage)
        exit(ExitCode.inputError.rawValue)
    }
case "--help", "-h", "help":
    print(usage)
    exit(0)
default:
    eprint("エラー: 不明なコマンドです: \(command)\n\n" + usage)
    exit(ExitCode.inputError.rawValue)
}
