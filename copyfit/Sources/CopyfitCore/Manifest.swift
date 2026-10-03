import Foundation

/// manifest.json（schemaVersion 1）。ファイル名からの推測ではなくmanifestを正とする。
public struct Manifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var ruleset: String?
    public var requiredLocales: [String]
    public var requiredTargets: [String]
    public var requiredSlots: [String]
    public var fallbackPolicy: String?
    public var fallbacks: [Fallback]?
    public var assets: [AssetSpec]
    public var copyAllowlist: [CopyAllowlistEntry]?
    public var breakAllowlist: [BreakAllowlistEntry]?
    public var noBreakPhrases: [String: [String]]?
    public var ocr: OCRSettings?
    public var heuristics: HeuristicSettings?

    public struct Fallback: Codable, Equatable, Sendable {
        public var locale: String
        public var target: String
        public var slot: String
        public var useLocale: String
        public var reason: String
    }

    public struct CopyAllowlistEntry: Codable, Equatable, Sendable {
        public var key: String
        public var reason: String
    }

    /// 意図した改行の許可。理由・対象・期限を必須にし、まとめての無効化はできない。
    public struct BreakAllowlistEntry: Codable, Equatable, Sendable {
        public var locale: String
        public var target: String
        public var slot: String
        public var regionID: String
        public var ruleID: String
        public var reason: String
        public var expires: String
    }

    public struct OCRSettings: Codable, Equatable, Sendable {
        public var enabled: Bool?
        public var minConfidence: Double?
        public var assignTolerancePx: Double?
        public var edgeTolerancePx: Double?
    }

    public struct HeuristicSettings: Codable, Equatable, Sendable {
        public var orphanLines: Bool?
        public var orphanMaxGraphemesCJK: Int?
    }
}

public struct AssetSpec: Codable, Equatable, Sendable {
    public var locale: String
    public var target: String
    public var slot: String
    public var path: String
    public var expectedPixelSize: [Int]?
    public var textRegions: [TextRegionSpec]?
    public var forbiddenRectsPx: [ForbiddenRect]?

    public var key: AssetKey { AssetKey(locale: locale, target: target, slot: slot) }
}

public struct TextRegionSpec: Codable, Equatable, Sendable {
    public var id: String
    public var copyKey: String
    public var rectPx: PixelRect
    public var maxLines: Int?
    public var fontPostScriptName: String?
    public var fontSizePx: Double?
    public var lineHeightPx: Double?
    public var trackingPx: Double?
    public var alignment: String?
    public var layoutMetadataVerified: Bool?

    /// layout検査に必要な情報が揃っているか。不足ならFIT001はUNKNOWN。
    public var layoutMetadata: LayoutMetadata? {
        guard let font = fontPostScriptName, !font.isEmpty, !font.hasPrefix("REPLACE_"),
              let size = fontSizePx, size > 0,
              let lh = lineHeightPx, lh > 0 else { return nil }
        return LayoutMetadata(fontPostScriptName: font, fontSizePx: size, lineHeightPx: lh,
                              trackingPx: trackingPx ?? 0, alignment: alignment ?? "left",
                              maxLines: maxLines)
    }
}

public struct LayoutMetadata: Equatable, Sendable {
    public var fontPostScriptName: String
    public var fontSizePx: Double
    public var lineHeightPx: Double
    public var trackingPx: Double
    public var alignment: String
    public var maxLines: Int?
}

/// 禁止領域。`[x,y,w,h]`の配列でも、`{id, rectPx, basis, note}`のobjectでも書ける。
public struct ForbiddenRect: Codable, Equatable, Sendable {
    public var id: String
    public var rectPx: PixelRect
    /// "project-rule"（社内design rule / 端末mockupのviewport外）。Apple公式要件とは呼ばない。
    public var note: String?

    public init(id: String, rectPx: PixelRect, note: String? = nil) {
        self.id = id
        self.rectPx = rectPx
        self.note = note
    }

    enum CodingKeys: String, CodingKey { case id, rectPx, note }

    public init(from decoder: Decoder) throws {
        if let rect = try? PixelRect(from: decoder) {
            self.init(id: "forbidden", rectPx: rect)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(String.self, forKey: .id) ?? "forbidden",
                  rectPx: try c.decode(PixelRect.self, forKey: .rectPx),
                  note: try c.decodeIfPresent(String.self, forKey: .note))
    }
}

public enum ManifestLoader {
    public static func load(data: Data) throws -> Manifest {
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw CopyfitError.invalidInput("manifest.jsonに必須項目 `\(key.stringValue)` がありません（\(pathString(ctx.codingPath))）")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw CopyfitError.invalidInput("manifest.jsonの型が不正です: \(pathString(ctx.codingPath)) \(ctx.debugDescription)")
        } catch let DecodingError.dataCorrupted(ctx) {
            throw CopyfitError.invalidInput("manifest.jsonを読めません: \(pathString(ctx.codingPath)) \(ctx.debugDescription)")
        } catch let e as CopyfitError {
            throw e
        } catch {
            throw CopyfitError.invalidInput("manifest.jsonを読めません: \(error)")
        }
        try validateStructure(manifest)
        return manifest
    }

    static func pathString(_ path: [CodingKey]) -> String {
        path.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
    }

    /// manifest自体の矛盾（ルール判定ではなく入力エラー）を検査する。
    static func validateStructure(_ m: Manifest) throws {
        guard m.schemaVersion == 1 else {
            throw CopyfitError.invalidInput("未対応のschemaVersion \(m.schemaVersion) です（対応: 1）")
        }
        if let p = m.fallbackPolicy, p != "explicit-only" && p != "none" {
            throw CopyfitError.invalidInput("fallbackPolicyは \"explicit-only\" または \"none\" です: \(p)")
        }
        if m.fallbackPolicy == "none", let f = m.fallbacks, !f.isEmpty {
            throw CopyfitError.invalidInput("fallbackPolicyが\"none\"なのにfallbacksが指定されています")
        }
        for (i, a) in m.assets.enumerated() {
            for field in [a.locale, a.target, a.slot, a.path] where field.trimmingCharacters(in: .whitespaces).isEmpty {
                throw CopyfitError.invalidInput("assets[\(i)] のlocale/target/slot/pathに空文字があります")
            }
            if let s = a.expectedPixelSize, s.count != 2 || s.contains(where: { $0 <= 0 }) {
                throw CopyfitError.invalidInput("assets[\(i)].expectedPixelSize は正の[幅, 高さ]です: \(s)")
            }
            var ids = Set<String>()
            for r in a.textRegions ?? [] {
                if !ids.insert(r.id).inserted {
                    throw CopyfitError.invalidInput("assets[\(i)] のtextRegions idが重複しています: \(r.id)")
                }
                if r.rectPx.width <= 0 || r.rectPx.height <= 0 || r.rectPx.x < 0 || r.rectPx.y < 0 {
                    throw CopyfitError.invalidInput("assets[\(i)].textRegions[\(r.id)].rectPx に負値または0幅があります: \(r.rectPx)")
                }
                if let ml = r.maxLines, ml <= 0 {
                    throw CopyfitError.invalidInput("assets[\(i)].textRegions[\(r.id)].maxLines は1以上です")
                }
            }
            for f in a.forbiddenRectsPx ?? [] where f.rectPx.width <= 0 || f.rectPx.height <= 0 || f.rectPx.x < 0 || f.rectPx.y < 0 {
                throw CopyfitError.invalidInput("assets[\(i)].forbiddenRectsPx[\(f.id)] に負値または0幅があります")
            }
        }
        for e in m.breakAllowlist ?? [] {
            if e.reason.trimmingCharacters(in: .whitespaces).isEmpty {
                throw CopyfitError.invalidInput("breakAllowlistの各項目には理由(reason)が必要です")
            }
            if parseDay(e.expires) == nil {
                throw CopyfitError.invalidInput("breakAllowlistのexpiresはYYYY-MM-DDです: \(e.expires)")
            }
        }
    }
}

func parseDay(_ s: String) -> Date? {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    guard s.count == 10 else { return nil }
    return f.date(from: s)
}
