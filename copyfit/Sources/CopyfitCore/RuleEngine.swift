import Foundation

/// 画像1枚の検査材料（I/Oの結果）。RuleEngineはこれだけを見て決定的に判定する。
public enum AssetInspection: Equatable, Sendable {
    case inspected(AssetFacts)
    case fileMissing(String)
}

public struct RuleInput: Sendable {
    public var manifest: Manifest
    public var copy: CopyTable
    public var ruleset: Ruleset?
    /// manifest.assetsのindex → 検査結果。ASSET002で重複したassetは検査しない（index欠落）。
    public var inspections: [Int: AssetInspection]
    public var ocr: [Int: OCROutcome]
    /// asset index → region id → layout計測結果。
    public var measurements: [Int: [String: MeasureOutcome]]
    public var now: Date

    public init(manifest: Manifest, copy: CopyTable, ruleset: Ruleset?, inspections: [Int: AssetInspection],
                ocr: [Int: OCROutcome] = [:], measurements: [Int: [String: MeasureOutcome]] = [:], now: Date) {
        self.manifest = manifest
        self.copy = copy
        self.ruleset = ruleset
        self.inspections = inspections
        self.ocr = ocr
        self.measurements = measurements
        self.now = now
    }
}

public enum RuleEngine {
    public static let defaultMinConfidence = 0.5
    public static let defaultAssignTolerancePx = 24.0
    public static let defaultEdgeTolerancePx = 2.0
    /// OCR矩形の誤差として許容するbox外へのはみ出し量。
    public static let ocrBoxTolerancePx = 4.0

    /// 同じkeyが複数あるasset index（ASSET002）。勝手に一方を選ばないため、検査対象から外す。
    public static func duplicateAssetIndices(_ m: Manifest) -> Set<Int> {
        var byKey: [AssetKey: [Int]] = [:]
        for (i, a) in m.assets.enumerated() { byKey[a.key, default: []].append(i) }
        return Set(byKey.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    public static func evaluate(_ input: RuleInput) -> [Finding] {
        var findings: [Finding] = []
        let m = input.manifest
        findings += rulesetFindings(input)
        findings += assetPresenceFindings(input)
        findings += copyTableFindings(input)

        let dups = duplicateAssetIndices(m)
        for (index, asset) in m.assets.enumerated() where !dups.contains(index) {
            findings += assetFindings(input, index: index, asset: asset)
        }
        return findings.sorted(by: findingOrder)
    }

    static func findingOrder(_ a: Finding, _ b: Finding) -> Bool {
        let ka = a.assetKey.map { [$0.locale, $0.target, $0.slot] } ?? ["", "", ""]
        let kb = b.assetKey.map { [$0.locale, $0.target, $0.slot] } ?? ["", "", ""]
        if ka != kb { return ka.lexicographicallyPrecedes(kb) }
        if (a.regionID ?? "") != (b.regionID ?? "") { return (a.regionID ?? "") < (b.regionID ?? "") }
        if a.ruleID != b.ruleID { return a.ruleID < b.ruleID }
        return a.message < b.message
    }

    // MARK: RULE001

    static func rulesetFindings(_ input: RuleInput) -> [Finding] {
        guard let requested = input.manifest.ruleset, !requested.isEmpty else {
            return [Finding(ruleID: "RULE001", basis: .toolMeta, assetKey: nil, status: .unknown,
                            message: "manifestにrulesetが指定されていません。Apple仕様に基づく寸法/alpha検査は行えません",
                            remediation: "manifest.rulesetに同梱ruleset ID（例: apple-screenshots-2026-10-03）を指定してください")]
        }
        guard let r = input.ruleset else {
            return [Finding(ruleID: "RULE001", basis: .toolMeta, assetKey: nil, status: .unknown,
                            message: "ruleset「\(requested)」が見つかりません。Apple仕様に基づく検査は行えません",
                            remediation: "同梱rulesetのIDを指定するか、--rulesetで確認済みrulesetファイルを渡してください")]
        }
        var out: [Finding] = []
        if r.rulesetID != requested {
            out.append(Finding(ruleID: "RULE001", basis: .toolMeta, assetKey: nil, status: .warn,
                               message: "manifestのruleset「\(requested)」と読み込んだruleset「\(r.rulesetID)」が異なります",
                               expectedValue: requested, remediation: "manifest.rulesetを実際に使うrulesetに合わせてください"))
        }
        if let age = r.ageInDays(now: input.now) {
            if age > r.maxAgeDays {
                out.append(Finding(ruleID: "RULE001", basis: .toolMeta, assetKey: nil, status: .warn,
                                   message: "ruleset「\(r.rulesetID)」は確認日\(r.checkedAt)から\(age)日経過しています（上限\(r.maxAgeDays)日）。Appleの最新仕様と再照合が必要です",
                                   evidence: r.sourceURLs, measuredValue: "\(age)日", expectedValue: "≤\(r.maxAgeDays)日",
                                   remediation: "公式ページを確認し、新しい日付のrulesetをfixtureとreview付きでcommitしてください"))
            } else {
                out.append(Finding(ruleID: "RULE001", basis: .toolMeta, assetKey: nil, status: .pass,
                                   message: "ruleset「\(r.rulesetID)」（確認日\(r.checkedAt)、\(age)日経過）を使用",
                                   evidence: r.sourceURLs))
            }
        } else {
            out.append(Finding(ruleID: "RULE001", basis: .toolMeta, assetKey: nil, status: .unknown,
                               message: "rulesetの確認日（checkedAt）を解釈できません: \(r.checkedAt)"))
        }
        return out
    }

    // MARK: ASSET001 / ASSET002 / ASSET003

    static func assetPresenceFindings(_ input: RuleInput) -> [Finding] {
        let m = input.manifest
        var out: [Finding] = []
        var byKey: [AssetKey: [Int]] = [:]
        for (i, a) in m.assets.enumerated() { byKey[a.key, default: []].append(i) }

        for (key, idx) in byKey where idx.count > 1 {
            out.append(Finding(ruleID: "ASSET002", basis: .projectRule, assetKey: key, status: .fail,
                               message: "同じlocale/target/slotの画像が\(idx.count)件あります。どちらを提出するか自動では選びません",
                               evidence: idx.map { "assets[\($0)]: \(m.assets[$0].path)" },
                               remediation: "manifestから不要な方を削除してください"))
        }

        func present(_ key: AssetKey) -> Bool {
            guard let idx = byKey[key], idx.count == 1 else { return false }
            if case .fileMissing = input.inspections[idx[0]] { return false }
            return input.inspections[idx[0]] != nil
        }

        let fallbacks = m.fallbackPolicy == "none" ? [] : (m.fallbacks ?? [])
        for locale in m.requiredLocales {
            for target in m.requiredTargets {
                for slot in m.requiredSlots {
                    let key = AssetKey(locale: locale, target: target, slot: slot)
                    if let idx = byKey[key], idx.count > 1 { continue }  // ASSET002で報告済み
                    if present(key) {
                        out.append(Finding(ruleID: "ASSET001", basis: .projectRule, assetKey: key, status: .pass,
                                           message: "必要な画像があります"))
                        continue
                    }
                    let fileNote: [String] = byKey[key].flatMap { idx in
                        if case .fileMissing(let p) = input.inspections[idx[0]] { return ["manifestに記載されたファイルが存在しません: \(p)"] }
                        return nil
                    } ?? ["manifestに記載がありません"]
                    if let fb = fallbacks.first(where: { $0.locale == locale && $0.target == target && $0.slot == slot }) {
                        let src = AssetKey(locale: fb.useLocale, target: target, slot: slot)
                        if present(src) {
                            out.append(Finding(ruleID: "ASSET001", basis: .projectRule, assetKey: key, status: .pass,
                                               message: "明示fallbackにより「\(src)」の画像を採用します",
                                               evidence: fileNote + ["fallback理由: \(fb.reason)"]))
                        } else {
                            out.append(Finding(ruleID: "ASSET001", basis: .projectRule, assetKey: key, status: .fail,
                                               message: "画像がなく、fallback元「\(src)」も存在しません",
                                               evidence: fileNote + ["fallback理由: \(fb.reason)"],
                                               remediation: "画像を追加するか、fallback設定を見直してください"))
                        }
                    } else {
                        out.append(Finding(ruleID: "ASSET001", basis: .projectRule, assetKey: key, status: .fail,
                                           message: "必要な画像がありません", evidence: fileNote,
                                           remediation: "画像を追加してmanifestに記載するか、明示fallbackを設定してください"))
                    }
                }
            }
        }
        if let max = input.ruleset?.maxScreenshotsPerSet, m.requiredSlots.count > max {
            out.append(Finding(ruleID: "ASSET003", basis: .appleOfficial, assetKey: nil, status: .fail,
                               message: "requiredSlotsが\(m.requiredSlots.count)枚で、Appleの上限\(max)枚を超えています",
                               measuredValue: "\(m.requiredSlots.count)", expectedValue: "≤\(max)"))
        }
        return out
    }

    // MARK: COPY001 (表全体) / COPY002

    static func copyTableFindings(_ input: RuleInput) -> [Finding] {
        var out: [Finding] = []
        var groups: [String: [CopyEntry]] = [:]
        for e in input.copy.entries { groups["\(e.locale)\u{0}\(e.key)", default: []].append(e) }
        for (_, es) in groups where es.count > 1 {
            out.append(Finding(ruleID: "COPY001", basis: .projectRule,
                               assetKey: AssetKey(locale: es[0].locale, target: "*", slot: "*"),
                               regionID: es[0].key, status: .fail,
                               message: "文言key「\(es[0].key)」が同じlocaleで\(es.count)回定義されています",
                               evidence: es.map { "\($0.origin): \($0.text)" },
                               remediation: "どちらか一方に統一してください（自動では選びません）"))
        }

        let allow = Set((input.manifest.copyAllowlist ?? []).map(\.key))
        let usedKeys = Set(input.manifest.assets.flatMap { ($0.textRegions ?? []).map(\.copyKey) })
        for key in usedKeys.sorted() where !allow.contains(key) {
            var byText: [String: [String]] = [:]
            for locale in input.manifest.requiredLocales {
                if let t = input.copy.text(locale: locale, key: key) { byText[t, default: []].append(locale) }
            }
            for (text, locales) in byText where locales.count > 1 {
                out.append(Finding(ruleID: "COPY002", basis: .heuristic, assetKey: nil, regionID: key, status: .warn,
                                   message: "文言key「\(key)」が\(locales.joined(separator: ", "))で同一です（翻訳漏れの可能性）",
                                   evidence: ["text: \(text)"],
                                   remediation: "意図した同一文言（ブランド名等）ならmanifest.copyAllowlistに理由付きで追加してください"))
            }
        }
        return out
    }

    // MARK: 画像単位

    static func assetFindings(_ input: RuleInput, index: Int, asset: AssetSpec) -> [Finding] {
        let key = asset.key
        guard let inspection = input.inspections[index] else { return [] }
        guard case .inspected(let facts) = inspection else { return [] }  // ASSET001で報告
        var out: [Finding] = []

        // IMAGE003: 破損
        if let problem = facts.integrityProblem {
            out.append(Finding(ruleID: "IMAGE003", basis: .appleOfficial, assetKey: key, status: .fail,
                               message: "画像を正しく読めません: \(problem)",
                               evidence: ["path: \(asset.path)"],
                               remediation: "デザインツールから書き出し直してください"))
            return out
        }

        out += imageFindings(input, key: key, asset: asset, facts: facts)

        let targetSize = (facts.pixelWidth, facts.pixelHeight)
        let ocrOutcome = input.ocr[index]
        for region in asset.textRegions ?? [] {
            guard region.rectPx.isValid(inWidth: targetSize.0, height: targetSize.1) else {
                out.append(Finding(ruleID: "FIT001", basis: .projectRule, assetKey: key, regionID: region.id, status: .unknown,
                                   message: "textRegionの矩形\(region.rectPx)が画像範囲 \(facts.pixelWidth)×\(facts.pixelHeight) の外にあるため、この領域は検査しません",
                                   remediation: "rectPxを画像の左上原点pixelで指定し直してください"))
                continue
            }
            out += regionFindings(input, key: key, asset: asset, facts: facts, region: region,
                                  measurement: input.measurements[index]?[region.id], ocr: ocrOutcome)
        }

        // FIT002（画像全体）: どの領域にも属さない文字が画像端に接している＝画像外へ切れている疑い。
        if case .observations(let obs)? = ocrOutcome {
            let edge = input.manifest.ocr?.edgeTolerancePx ?? defaultEdgeTolerancePx
            let regions = asset.textRegions ?? []
            let tol = input.manifest.ocr?.assignTolerancePx ?? defaultAssignTolerancePx
            for o in obs where !regions.contains(where: { assign(o, to: $0.rectPx, tolerance: tol) })
                && touchesEdge(o.boundingBox, facts: facts, tolerance: edge) {
                out.append(Finding(ruleID: "FIT002", basis: .heuristic, assetKey: key, status: .warn,
                                   message: "領域外の文字「\(o.text)」が画像端に接しています（画像外へ切れている疑い）",
                                   evidence: ["OCR box: \(o.boundingBox)", "confidence: \(String(format: "%.2f", o.confidence))"],
                                   remediation: "元デザインで文字が画像外へはみ出していないか確認してください"))
            }
        }
        return out
    }

    static func imageFindings(_ input: RuleInput, key: AssetKey, asset: AssetSpec, facts: AssetFacts) -> [Finding] {
        var out: [Finding] = []
        let actual = "\(facts.pixelWidth)×\(facts.pixelHeight)"
        let r = input.ruleset

        // format
        let formatOK = r?.acceptedFormats.contains(facts.format.rawValue) ?? (facts.format != .unknown)
        if !formatOK || facts.format == .unknown {
            out.append(Finding(ruleID: "IMAGE001", basis: .appleOfficial, assetKey: key, status: .fail,
                               message: "対応していない画像形式です（\(facts.format.rawValue)）",
                               expectedValue: (r?.acceptedFormats ?? ["png", "jpeg"]).joined(separator: "/")))
        }
        if facts.extensionMismatch {
            out.append(Finding(ruleID: "IMAGE001", basis: .projectRule, assetKey: key, status: .warn,
                               message: "拡張子と実際の形式（\(facts.format.rawValue)）が一致しません",
                               evidence: ["path: \(asset.path)"], remediation: "正しい拡張子で書き出し直してください"))
        }

        // 寸法: manifestの期待値
        if let e = asset.expectedPixelSize {
            if e == [facts.pixelWidth, facts.pixelHeight] {
                out.append(Finding(ruleID: "IMAGE001", basis: .projectRule, assetKey: key, status: .pass,
                                   message: "寸法がmanifestの指定と一致します", measuredValue: actual))
            } else {
                let swapped = e == [facts.pixelHeight, facts.pixelWidth]
                out.append(Finding(ruleID: "IMAGE001", basis: .projectRule, assetKey: key, status: .fail,
                                   message: swapped ? "縦横が逆です" : "寸法がmanifestの指定と一致しません",
                                   evidence: facts.orientation != 1 ? ["EXIF orientation \(facts.orientation) を適用後の寸法"] : [],
                                   measuredValue: actual, expectedValue: "\(e[0])×\(e[1])",
                                   remediation: "指定サイズで書き出し直してください（リサイズによるにじみにも注意）"))
            }
        }

        // 寸法: Apple ruleset
        if let r {
            if let t = r.target(asset.target) {
                if t.allows(width: facts.pixelWidth, height: facts.pixelHeight) {
                    out.append(Finding(ruleID: "IMAGE001", basis: .appleOfficial, assetKey: key, status: .pass,
                                       message: "\(t.displayName)の許容寸法です", measuredValue: actual))
                } else {
                    out.append(Finding(ruleID: "IMAGE001", basis: .appleOfficial, assetKey: key, status: .fail,
                                       message: "\(t.displayName)の許容寸法ではありません",
                                       evidence: ["ruleset: \(r.rulesetID)"], measuredValue: actual,
                                       expectedValue: t.allowedPixelSizes.map { "\($0[0])×\($0[1])" }.joined(separator: ", ")))
                }
            } else {
                out.append(Finding(ruleID: "RULE001", basis: .toolMeta, assetKey: key, status: .unknown,
                                   message: "target「\(asset.target)」はruleset「\(r.rulesetID)」にありません。Apple寸法は検査できません",
                                   evidence: ["既知target: " + r.targets.map(\.id).joined(separator: ", ")],
                                   remediation: "既知のtarget IDを使うか、公式仕様を確認してrulesetを更新してください"))
            }
            if facts.hasAlphaChannel && !r.alphaAllowed {
                out.append(Finding(ruleID: "IMAGE002", basis: .appleOfficial, assetKey: key, status: .fail,
                                   message: "alpha channel/透過情報を含みます（Apple: alpha/透過不可）",
                                   evidence: ["color: \(facts.colorDescription)", "ruleset: \(r.rulesetID)"],
                                   remediation: "alphaなし（RGB）で書き出し直してください"))
            } else {
                out.append(Finding(ruleID: "IMAGE002", basis: .appleOfficial, assetKey: key, status: .pass,
                                   message: "alpha channelはありません", measuredValue: facts.colorDescription))
            }
        } else {
            out.append(Finding(ruleID: "IMAGE002", basis: .appleOfficial, assetKey: key, status: .unknown,
                               message: "rulesetがないためalpha/寸法のApple仕様検査を行えません",
                               measuredValue: "\(actual) \(facts.colorDescription)"))
        }
        return out
    }

    // MARK: 領域単位

    static func regionFindings(_ input: RuleInput, key: AssetKey, asset: AssetSpec, facts: AssetFacts,
                               region: TextRegionSpec, measurement: MeasureOutcome?, ocr: OCROutcome?) -> [Finding] {
        var out: [Finding] = []
        let rid = region.id
        let verified = region.layoutMetadataVerified == true
        let forbidden = asset.forbiddenRectsPx ?? []

        // COPY001
        let entries = input.copy.entries(locale: key.locale, key: region.copyKey)
        let text: String?
        if entries.isEmpty {
            out.append(Finding(ruleID: "COPY001", basis: .projectRule, assetKey: key, regionID: rid, status: .fail,
                               message: "文言key「\(region.copyKey)」が\(key.locale)にありません",
                               remediation: "文言ファイルに追加してください"))
            text = nil
        } else if entries.count > 1 {
            text = nil  // 重複は表全体で報告済み
        } else if entries[0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(Finding(ruleID: "COPY001", basis: .projectRule, assetKey: key, regionID: rid, status: .fail,
                               message: "文言key「\(region.copyKey)」が空です", evidence: [entries[0].origin]))
            text = nil
        } else {
            text = entries[0].text
        }

        // SAFE001: 指定box自体が禁止領域へ侵入
        for f in forbidden where region.rectPx.intersects(f.rectPx) {
            out.append(Finding(ruleID: "SAFE001", basis: .projectRule, assetKey: key, regionID: rid,
                               status: verified ? .fail : .warn,
                               message: "テキストbox\(region.rectPx)が禁止領域「\(f.id)」\(f.rectPx)に重なっています" + (verified ? "" : "（layout metadata未検証のためWARN）"),
                               evidence: f.note.map { ["禁止領域: \($0)"] } ?? [],
                               remediation: "テキストboxを禁止領域の外へ移動してください"))
        }

        // FIT001
        var layoutLines: [String]?
        if text != nil {
            if let meta = region.layoutMetadata {
                switch measurement {
                case .measured(let mm)?:
                    layoutLines = mm.lines
                    out += fitFindings(key: key, region: region, meta: meta, m: mm, verified: verified, forbidden: forbidden)
                case .fontMissing(let name)?:
                    out.append(Finding(ruleID: "FIT001", basis: .projectRule, assetKey: key, regionID: rid, status: .unknown,
                                       message: "font「\(name)」がこの環境にありません。代替fontでの計測は行いません",
                                       remediation: "指定fontをインストールするか、正しいPostScript名を指定してください"))
                case .unavailable(let why)?:
                    out.append(Finding(ruleID: "FIT001", basis: .projectRule, assetKey: key, regionID: rid, status: .unknown,
                                       message: "文字fit計測を行えません: \(why)"))
                case nil:
                    out.append(Finding(ruleID: "FIT001", basis: .projectRule, assetKey: key, regionID: rid, status: .unknown,
                                       message: "文字fit計測結果がありません"))
                }
            } else {
                out.append(Finding(ruleID: "FIT001", basis: .projectRule, assetKey: key, regionID: rid, status: .unknown,
                                   message: "font名・サイズ・行高のいずれかが未指定のため、文字fitを判定できません",
                                   remediation: "textRegionにfontPostScriptName/fontSizePx/lineHeightPxを指定してください"))
            }
        }

        // OCR
        var ocrLines: [String]?
        if let text {
            let r = ocrFindings(input, key: key, facts: facts, region: region, expected: text, ocr: ocr, forbidden: forbidden)
            out += r.findings
            ocrLines = r.lines
        }

        // BREAK001/002
        if let text {
            out += breakFindings(input, key: key, region: region, text: text, layoutLines: layoutLines, ocrLines: ocrLines)
        }
        return out
    }

    static func fitFindings(key: AssetKey, region: TextRegionSpec, meta: LayoutMetadata, m: LayoutMeasurement,
                            verified: Bool, forbidden: [ForbiddenRect]) -> [Finding] {
        var out: [Finding] = []
        var problems: [String] = []
        if !m.allGlyphsPlaced { problems.append("box内に全文字を配置できません") }
        if let ml = meta.maxLines, m.lines.count > ml { problems.append("行数\(m.lines.count)が上限\(ml)を超えています") }
        let over = region.rectPx.overflow(of: m.inkBounds)
        if over > 0.5 { problems.append("ink範囲がboxから\(fmt(over))pxはみ出しています") }
        let evidence = ["layout行: " + m.lines.map { "「\($0)」" }.joined(separator: " / "),
                        "font: \(meta.fontPostScriptName) \(fmt(meta.fontSizePx))px / 行高\(fmt(meta.lineHeightPx))px / tracking \(fmt(meta.trackingPx))px",
                        "ink: \(m.inkBounds) box: \(region.rectPx)",
                        "モデル計測: デザインツールの組版と字形・カーニングが一致しない場合があります"]
        if problems.isEmpty {
            out.append(Finding(ruleID: "FIT001", basis: .projectRule, assetKey: key, regionID: region.id,
                               status: verified ? .pass : .unknown,
                               message: verified ? "指定layoutで\(m.lines.count)行に収まります"
                                   : "モデル上は収まりますが、layout metadataが未検証のためPASSにしません",
                               evidence: evidence, measuredValue: "\(m.lines.count)行",
                               expectedValue: meta.maxLines.map { "≤\($0)行" },
                               remediation: verified ? nil : "デザイン元とfont/サイズ/行高を照合し、layoutMetadataVerified: trueにしてください"))
        } else {
            out.append(Finding(ruleID: "FIT001", basis: .projectRule, assetKey: key, regionID: region.id,
                               status: verified ? .fail : .warn,
                               message: problems.joined(separator: "、") + (verified ? "" : "（metadata未検証のためWARN）"),
                               evidence: evidence, measuredValue: "\(m.lines.count)行 ink \(m.inkBounds)",
                               expectedValue: (meta.maxLines.map { "≤\($0)行 " } ?? "") + "box \(region.rectPx)",
                               remediation: "文言を短くする、boxを広げる、font sizeを下げる等を検討してください"))
        }
        for f in forbidden where m.inkBounds.intersects(f.rectPx) && !region.rectPx.intersects(f.rectPx) {
            out.append(Finding(ruleID: "SAFE001", basis: .projectRule, assetKey: key, regionID: region.id,
                               status: verified ? .fail : .warn,
                               message: "計測したink範囲が禁止領域「\(f.id)」に侵入しています",
                               evidence: ["ink: \(m.inkBounds)", "禁止領域: \(f.rectPx)"]))
        }
        return out
    }

    static func assign(_ o: OCRObservation, to rect: PixelRect, tolerance: Double) -> Bool {
        rect.insetBy(-tolerance).containsPoint(x: o.boundingBox.midX, y: o.boundingBox.midY)
    }

    static func touchesEdge(_ r: PixelRect, facts: AssetFacts, tolerance: Double) -> Bool {
        r.minX <= tolerance || r.minY <= tolerance
            || r.maxX >= Double(facts.pixelWidth) - tolerance || r.maxY >= Double(facts.pixelHeight) - tolerance
    }

    static func ocrFindings(_ input: RuleInput, key: AssetKey, facts: AssetFacts, region: TextRegionSpec,
                            expected: String, ocr: OCROutcome?, forbidden: [ForbiddenRect]) -> (findings: [Finding], lines: [String]?) {
        let rid = region.id
        func unknown(_ msg: String, _ ev: [String] = []) -> (findings: [Finding], lines: [String]?) {
            ([Finding(ruleID: "TEXT001", basis: .heuristic, assetKey: key, regionID: rid, status: .unknown,
                      message: msg, evidence: ["期待文言: \(expected)"] + ev,
                      remediation: "目視で確認してください")], nil)
        }
        guard let ocr else { return unknown("OCRを実行していません（--no-ocr / manifestで無効 / 非対応環境）") }
        let obs: [OCRObservation]
        switch ocr {
        case .unavailable(let why): return unknown("OCRを利用できません: \(why)")
        case .unsupportedLanguage(let lang): return unknown("OCRが言語「\(lang)」に対応していません")
        case .failed(let why): return unknown("OCRに失敗しました: \(why)")
        case .observations(let o): obs = o
        }
        let tol = input.manifest.ocr?.assignTolerancePx ?? defaultAssignTolerancePx
        let minConf = input.manifest.ocr?.minConfidence ?? defaultMinConfidence
        let edge = input.manifest.ocr?.edgeTolerancePx ?? defaultEdgeTolerancePx
        let mine = obs.filter { assign($0, to: region.rectPx, tolerance: tol) }
            .sorted { abs($0.boundingBox.midY - $1.boundingBox.midY) > $0.boundingBox.height / 2
                ? $0.boundingBox.midY < $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX }
        if mine.isEmpty {
            return unknown("この領域でOCRが文字を読めませんでした（文字の欠落とは断定しません）")
        }
        var out: [Finding] = []
        let ocrText = mine.map(\.text).joined(separator: "\n")
        let minSeen = mine.map(\.confidence).min() ?? 0
        let ev = ["OCR: \(ocrText.replacingOccurrences(of: "\n", with: " / "))",
                  "最低confidence: \(String(format: "%.2f", minSeen))", "engine: \(mine[0].engineRevision)"]

        // FIT002: OCR矩形がbox/禁止領域/画像端に接触
        for o in mine {
            let over = region.rectPx.overflow(of: o.boundingBox)
            if over > ocrBoxTolerancePx {
                out.append(Finding(ruleID: "FIT002", basis: .heuristic, assetKey: key, regionID: rid, status: .warn,
                                   message: "OCRの文字領域「\(o.text)」がboxから約\(fmt(over))pxはみ出しています（OCR誤差を含む）",
                                   evidence: ["OCR box: \(o.boundingBox)", "box: \(region.rectPx)"],
                                   remediation: "画像を原寸で確認してください"))
            }
            if touchesEdge(o.boundingBox, facts: facts, tolerance: edge) {
                out.append(Finding(ruleID: "FIT002", basis: .heuristic, assetKey: key, regionID: rid, status: .warn,
                                   message: "OCRの文字領域「\(o.text)」が画像端に接しています（画像外へ切れている疑い）",
                                   evidence: ["OCR box: \(o.boundingBox)"]))
            }
            for f in forbidden where o.boundingBox.intersects(f.rectPx) {
                out.append(Finding(ruleID: "FIT002", basis: .heuristic, assetKey: key, regionID: rid, status: .warn,
                                   message: "OCRの文字領域「\(o.text)」が禁止領域「\(f.id)」に接触しています（画像推定）",
                                   evidence: ["OCR box: \(o.boundingBox)", "禁止領域: \(f.rectPx)"]))
            }
        }

        if minSeen < minConf {
            out.append(Finding(ruleID: "TEXT001", basis: .heuristic, assetKey: key, regionID: rid, status: .unknown,
                               message: "OCRのconfidenceが低いため照合結果を採用しません（\(String(format: "%.2f", minSeen)) < \(minConf)）",
                               evidence: ["期待文言: \(expected)"] + ev, remediation: "目視で確認してください"))
            return (out, nil)
        }
        let e = TextNormalizer.normalizeForComparison(expected, locale: key.locale)
        let a = TextNormalizer.normalizeForComparison(ocrText, locale: key.locale)
        if e == a {
            out.append(Finding(ruleID: "TEXT001", basis: .heuristic, assetKey: key, regionID: rid, status: .pass,
                               message: "OCR結果が期待文言と一致します", evidence: ev))
        } else {
            out.append(Finding(ruleID: "TEXT001", basis: .heuristic, assetKey: key, regionID: rid, status: .warn,
                               message: "OCR結果が期待文言と一致しません（欠け・旧文言・OCR誤読の可能性）",
                               evidence: ["期待文言: \(expected)"] + ev + [TextNormalizer.diffSummary(expected: e, actual: a)],
                               measuredValue: ocrText, expectedValue: expected,
                               remediation: "画像の文言が最新か、文字が切れていないか確認してください"))
        }
        return (out, mine.map(\.text))
    }

    static func breakFindings(_ input: RuleInput, key: AssetKey, region: TextRegionSpec, text: String,
                              layoutLines: [String]?, ocrLines: [String]?) -> [Finding] {
        let rid = region.id
        let explicit = text.components(separatedBy: "\n")
        let source: String
        let lines: [String]
        if let layoutLines {
            (source, lines) = ("layoutモデル", layoutLines)
        } else if explicit.count > 1 {
            (source, lines) = ("文言の明示改行", explicit)
        } else if let ocrLines, !ocrLines.isEmpty {
            (source, lines) = ("OCR行（推定）", ocrLines)
        } else {
            return [Finding(ruleID: "BREAK001", basis: .projectRule, assetKey: key, regionID: rid, status: .unknown,
                            message: "改行位置の情報（layout計測/明示改行/OCR行）がないため、改行を検査できません")]
        }
        let h = input.manifest.heuristics
        let violations = LineBreakRules.check(
            lines: lines, locale: key.locale,
            noBreakPhrases: input.manifest.noBreakPhrases?[key.locale] ?? [],
            orphanCheck: h?.orphanLines ?? true,
            orphanMaxGraphemesCJK: h?.orphanMaxGraphemesCJK ?? 2)

        let allow = (input.manifest.breakAllowlist ?? []).filter {
            $0.locale == key.locale && $0.target == key.target && $0.slot == key.slot && $0.regionID == rid
        }
        var out: [Finding] = []
        let ev = ["行の出典: \(source)", "行: " + lines.map { "「\($0)」" }.joined(separator: " / ")]
        for ruleID in ["BREAK001", "BREAK002"] {
            let vs = violations.filter { $0.ruleID == ruleID }
            let basis: RuleBasis = ruleID == "BREAK002" ? .heuristic : .projectRule
            if vs.isEmpty {
                if ruleID == "BREAK002" && lines.count < 2 { continue }
                out.append(Finding(ruleID: ruleID, basis: basis, assetKey: key, regionID: rid, status: .pass,
                                   message: "改行の問題は見つかりません（\(source)）", evidence: ev))
                continue
            }
            if let a = allow.first(where: { $0.ruleID == ruleID }) {
                if let exp = parseDay(a.expires), exp >= input.now.addingTimeInterval(-86_400) {
                    out.append(Finding(ruleID: ruleID, basis: basis, assetKey: key, regionID: rid, status: .pass,
                                       message: "allowlistにより許可された改行です（理由: \(a.reason)、期限 \(a.expires)）",
                                       evidence: ev + vs.map(\.detail)))
                    continue
                }
                out.append(Finding(ruleID: ruleID, basis: basis, assetKey: key, regionID: rid, status: .warn,
                                   message: vs.map(\.detail).joined(separator: "、") + "（allowlistは \(a.expires) で期限切れ）",
                                   evidence: ev, remediation: "改行を直すか、allowlistの期限を見直してください"))
                continue
            }
            out.append(Finding(ruleID: ruleID, basis: basis, assetKey: key, regionID: rid, status: .warn,
                               message: vs.map(\.detail).joined(separator: "、"),
                               evidence: ev,
                               remediation: "改行位置を調整してください。意図した改行ならbreakAllowlistに理由と期限付きで追加してください"))
        }
        return out
    }
}
