import Foundation
@testable import CopyfitCore

enum TestPaths {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = packageRoot.appendingPathComponent("Fixtures")
    static let golden = packageRoot.appendingPathComponent("Tests/CopyfitCoreTests/Golden")
}

func day(_ s: String) -> Date { parseDay(s)! }

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("copyfit-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func region(_ id: String = "headline", key: String = "headline", rect: [Double] = [80, 160, 1130, 300],
            verified: Bool = true, font: String? = "Helvetica-Bold", maxLines: Int? = 2) -> TextRegionSpec {
    TextRegionSpec(id: id, copyKey: key, rectPx: try! PixelRect(array: rect), maxLines: maxLines,
                   fontPostScriptName: font, fontSizePx: 96, lineHeightPx: 120, trackingPx: 0,
                   alignment: "center", layoutMetadataVerified: verified)
}

func manifest(assets: [AssetSpec], locales: [String] = ["en-US"], targets: [String] = ["iphone-6.9"],
              slots: [String] = ["01"], ruleset: String? = "apple-screenshots-2026-10-03") -> Manifest {
    Manifest(schemaVersion: 1, ruleset: ruleset, requiredLocales: locales, requiredTargets: targets,
             requiredSlots: slots, fallbackPolicy: "explicit-only", fallbacks: nil, assets: assets,
             copyAllowlist: nil, breakAllowlist: nil, noBreakPhrases: nil, ocr: nil, heuristics: nil)
}

func assetSpec(locale: String = "en-US", target: String = "iphone-6.9", slot: String = "01",
               regions: [TextRegionSpec] = [region()], forbidden: [ForbiddenRect] = []) -> AssetSpec {
    AssetSpec(locale: locale, target: target, slot: slot, path: "images/\(locale)/\(target)/\(slot).png",
              expectedPixelSize: [1290, 2796], textRegions: regions, forbiddenRectsPx: forbidden)
}

let goodFacts = AssetFacts(pixelWidth: 1290, pixelHeight: 2796, format: .png, hasAlphaChannel: false,
                           colorDescription: "RGB 8bit")

func bundledRuleset() -> Ruleset { RulesetLoader.bundled(id: "apple-screenshots-2026-10-03")! }

extension Array where Element == Finding {
    func with(_ rule: String, region: String? = nil) -> [Finding] {
        filter { $0.ruleID == rule && (region == nil || $0.regionID == region) }
    }
}
