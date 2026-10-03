import Foundation

public struct AuditOptions: Sendable {
    public var ocrEnabled = true
    public var rulesetURL: URL?
    public var now = Date()
    public var limits = Limits()
    public var maxConcurrency = 4
    /// golden test用にOS表記を固定する。
    public var osVersionOverride: String?

    public init() {}
}

/// I/Oを担当し、RuleEngineへ正規化済みfactsを渡す。入力ファイルは読むだけで変更しない。
public struct Auditor: Sendable {
    public var ocr: OCRProvider
    public var measurer: TextMeasurer
    /// OSのデコーダで画像を実際に開けるか（macOSのImageIO）。nil = 構造検査のみ。
    public var decodeCheck: (@Sendable (URL) -> String?)?

    public init(ocr: OCRProvider, measurer: TextMeasurer, decodeCheck: (@Sendable (URL) -> String?)? = nil) {
        self.ocr = ocr
        self.measurer = measurer
        self.decodeCheck = decodeCheck
    }

    public struct Result: Sendable {
        public var report: AuditReport
        /// asset index → 元画像URL（reportへのコピー用）。
        public var imageURLs: [Int: URL]
        /// 検査開始時に読んだ入力ファイルのhash（終了時の不変確認用）。
        public var inputFiles: [URL: String]
    }

    public func run(manifestURL: URL, copyURL: URL, options: AuditOptions) throws -> Result {
        let manifestData = try readLimited(manifestURL, limit: options.limits.maxCopyBytes, what: "manifest")
        let manifest = try ManifestLoader.load(data: manifestData)
        if manifest.assets.count > options.limits.maxAssets {
            throw CopyfitError.limitExceeded("assetsが\(manifest.assets.count)件あり、1回の上限\(options.limits.maxAssets)件を超えています")
        }
        let copyData = try readLimited(copyURL, limit: options.limits.maxCopyBytes, what: "文言ファイル")
        let copy = try CopyLoader.load(data: copyData, fileExtension: copyURL.pathExtension)

        var inputFiles: [URL: String] = [manifestURL: SHA256.hex(manifestData), copyURL: SHA256.hex(copyData)]
        var inputHashes: [String: String] = [
            manifestURL.lastPathComponent: SHA256.hex(manifestData),
            copyURL.lastPathComponent: SHA256.hex(copyData),
        ]

        let ruleset: Ruleset?
        if let url = options.rulesetURL {
            let data = try readLimited(url, limit: options.limits.maxCopyBytes, what: "ruleset")
            ruleset = try RulesetLoader.load(data: data)
            inputHashes["ruleset:" + url.lastPathComponent] = SHA256.hex(data)
        } else {
            ruleset = manifest.ruleset.flatMap(RulesetLoader.bundled(id:))
        }

        let guardian = PathGuard(root: manifestURL.deletingLastPathComponent())
        let dups = RuleEngine.duplicateAssetIndices(manifest)
        var inspections: [Int: AssetInspection] = [:]
        var urls: [Int: URL] = [:]
        for (i, asset) in manifest.assets.enumerated() where !dups.contains(i) {
            let url = try guardian.resolve(asset.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                inspections[i] = .fileMissing(asset.path)
                continue
            }
            let data = try readLimited(url, limit: options.limits.maxFileBytes, what: "画像 \(asset.path)")
            var facts: AssetFacts
            do {
                facts = try ImageInspector.inspect(data: data, fileExtension: url.pathExtension, limits: options.limits)
            } catch let CopyfitError.limitExceeded(m) {
                throw CopyfitError.limitExceeded("\(asset.path): \(m)")
            }
            if facts.integrityProblem == nil, let check = decodeCheck, let problem = check(url) {
                facts.integrityProblem = problem
            }
            inspections[i] = .inspected(facts)
            urls[i] = url
            inputFiles[url] = facts.fileHash
            inputHashes[asset.path] = facts.fileHash
        }

        // OCR（並列数を制限）
        var ocrResults: [Int: OCROutcome] = [:]
        let ocrEnabled = options.ocrEnabled && (manifest.ocr?.enabled ?? true)
        if ocrEnabled {
            let supported = ocr.supportedLanguages()
            let jobs: [(Int, URL, AssetFacts, String)] = urls.keys.sorted().compactMap { i in
                guard case .inspected(let f)? = inspections[i], f.integrityProblem == nil,
                      !(manifest.assets[i].textRegions ?? []).isEmpty else { return nil }
                return (i, urls[i]!, f, manifest.assets[i].locale)
            }
            let lock = NSLock()
            for batch in stride(from: 0, to: jobs.count, by: max(1, options.maxConcurrency)) {
                let slice = Array(jobs[batch..<min(jobs.count, batch + max(1, options.maxConcurrency))])
                DispatchQueue.concurrentPerform(iterations: slice.count) { n in
                    let (i, url, facts, locale) = slice[n]
                    let outcome: OCROutcome
                    if let supported {
                        if let lang = Auditor.matchLanguage(locale, supported: supported) {
                            do { outcome = .observations(try ocr.recognize(imageURL: url, facts: facts, languages: [lang])) }
                            catch { outcome = .failed("\(error)") }
                        } else {
                            outcome = .unsupportedLanguage(locale)
                        }
                    } else {
                        outcome = .unavailable(ocr.engineDescription)
                    }
                    lock.lock(); ocrResults[i] = outcome; lock.unlock()
                }
            }
        }

        // layout計測
        var measurements: [Int: [String: MeasureOutcome]] = [:]
        for (i, asset) in manifest.assets.enumerated() {
            guard case .inspected(let f)? = inspections[i], f.integrityProblem == nil else { continue }
            for region in asset.textRegions ?? [] {
                guard let meta = region.layoutMetadata,
                      let text = copy.text(locale: asset.locale, key: region.copyKey),
                      region.rectPx.isValid(inWidth: f.pixelWidth, height: f.pixelHeight) else { continue }
                measurements[i, default: [:]][region.id] = measurer.measure(text: text, metadata: meta,
                                                                          rect: region.rectPx, locale: asset.locale)
            }
        }

        let input = RuleInput(manifest: manifest, copy: copy, ruleset: ruleset, inspections: inspections,
                              ocr: ocrResults, measurements: measurements, now: options.now)
        let findings = RuleEngine.evaluate(input)

        let entries: [AssetReportEntry] = manifest.assets.enumerated().map { i, a in
            var facts: AssetFacts?
            if case .inspected(let f)? = inspections[i] { facts = f }
            var obs: [OCRObservation] = []
            var note: String?
            switch ocrResults[i] {
            case .observations(let o)?: obs = o
            case .unavailable(let w)?: note = "OCR利用不可: \(w)"
            case .unsupportedLanguage(let l)?: note = "OCR非対応言語: \(l)"
            case .failed(let w)?: note = "OCR失敗: \(w)"
            case nil: note = dups.contains(i) ? "重複のため未検査" : (ocrEnabled ? nil : "OCR無効")
            }
            let regions = (a.textRegions ?? []).map { r -> RegionOverlay in
                var ink: PixelRect?
                if case .measured(let m)? = measurements[i]?[r.id] { ink = m.inkBounds }
                return RegionOverlay(id: r.id, rect: r.rectPx, expectedCopy: copy.text(locale: a.locale, key: r.copyKey),
                                     measuredInkBounds: ink)
            }
            return AssetReportEntry(key: a.key, path: a.path, facts: facts, reportImagePath: nil, regions: regions,
                                    forbiddenRects: a.forbiddenRectsPx ?? [], ocrObservations: obs, ocrNote: note)
        }

        let summary = Summary(findings: findings, assetsDeclared: manifest.assets.count,
                              assetsInspected: inspections.values.filter { if case .inspected = $0 { return true }; return false }.count)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let report = AuditReport(
            schemaVersion: reportSchemaVersion, toolVersion: copyfitToolVersion,
            rulesetVersion: ruleset?.rulesetID ?? (manifest.ruleset ?? "none"),
            rulesetCheckedAt: ruleset?.checkedAt,
            osVersion: options.osVersionOverride ?? ProcessInfo.processInfo.operatingSystemVersionString,
            generatedAt: iso.string(from: options.now),
            ocrEngine: ocrEnabled ? ocr.engineDescription : "disabled",
            textMeasurer: measurer.engineDescription,
            inputHashes: inputHashes, summary: summary, findings: findings, assets: entries,
            disclaimer: "本レポートは提出前のローカル検査結果であり、App Store審査・アップロードの成功を保証しません。UNKNOWNは「検査できなかった」ことを意味し、問題がないことを意味しません。")
        return Result(report: report, imageURLs: urls, inputFiles: inputFiles)
    }

    /// "ja-JP" → 対応一覧の "ja-JP" / "ja"。言語部分のみ一致でも可。
    static func matchLanguage(_ locale: String, supported: [String]) -> String? {
        if supported.contains(locale) { return locale }
        let lang = locale.split(separator: "-").first.map(String.init) ?? locale
        return supported.first { $0 == lang || $0.hasPrefix(lang + "-") }
    }

    func readLimited(_ url: URL, limit: Int, what: String) throws -> Data {
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: url.path) } catch {
            throw CopyfitError.io("\(what)を開けません: \(url.path)")
        }
        if let size = (attrs[.size] as? NSNumber)?.intValue, size > limit {
            throw CopyfitError.limitExceeded("\(what)のサイズ\(size) bytesが上限\(limit) bytesを超えています")
        }
        do { return try Data(contentsOf: url) } catch {
            throw CopyfitError.io("\(what)を読めません: \(url.path)")
        }
    }

    /// 終了時に入力が変更されていないことを確認する。
    public static func verifyUnchanged(_ files: [URL: String]) throws {
        for (url, hash) in files {
            guard let data = try? Data(contentsOf: url), SHA256.hex(data) == hash else {
                throw CopyfitError.io("検査中に入力ファイルが変更されました: \(url.path)")
            }
        }
    }
}
