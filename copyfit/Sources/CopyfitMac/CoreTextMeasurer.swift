#if canImport(CoreText) && canImport(CoreGraphics)
import CopyfitCore
import CoreGraphics
import CoreText
import Foundation

/// 期待文言を指定font/size/行高/trackingでboxへ組み、行・全glyph配置可否・ink範囲を返す。
/// デザインツール（Figma/Sketch等）の組版エンジンとは字形・カーニング・改行規則が一致しない場合がある。
public struct CoreTextMeasurer: TextMeasurer {
    public init() {}

    public var engineDescription: String { "CoreText (macOS)" }

    public func measure(text: String, metadata: LayoutMetadata, rect: PixelRect, locale: String) -> MeasureOutcome {
        let font = CTFontCreateWithName(metadata.fontPostScriptName as CFString, CGFloat(metadata.fontSizePx), nil)
        let actualName = CTFontCopyPostScriptName(font) as String
        guard actualName == metadata.fontPostScriptName else {
            // CoreTextは見つからないfontを黙って代替するため、名前一致で確認する。
            return .fontMissing(metadata.fontPostScriptName)
        }

        var alignment: CTTextAlignment
        switch metadata.alignment.lowercased() {
        case "center": alignment = .center
        case "right": alignment = .right
        case "justified": alignment = .justified
        default: alignment = .left
        }
        var lineHeight = CGFloat(metadata.lineHeightPx)
        var lineBreak = CTLineBreakMode.byWordWrapping
        // pointerはclosure内でだけ有効なので、CTParagraphStyleもclosure内で作る。
        let paragraph: CTParagraphStyle = withUnsafeBytes(of: &alignment) { a in
            withUnsafeBytes(of: &lineHeight) { lh in
                withUnsafeBytes(of: &lineBreak) { lb in
                    let settings = [
                        CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a.baseAddress!),
                        CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: lh.baseAddress!),
                        CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: lh.baseAddress!),
                        CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: lb.baseAddress!),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTKernAttributeName: NSNumber(value: metadata.trackingPx),
            kCTParagraphStyleAttributeName: paragraph,
            kCTLanguageAttributeName: locale as CFString,
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let length = CFAttributedStringGetLength(attributed)

        // 1) 指定boxの大きさで全文字が入るか
        let boxPath = CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: rect.height), transform: nil)
        let boxFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), boxPath, nil)
        let visible = CTFrameGetVisibleStringRange(boxFrame)
        let allPlaced = visible.length >= length

        // 2) 高さ無制限で組んだ全行とink範囲
        let tallHeight: CGFloat = 1_000_000
        let tallPath = CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: tallHeight), transform: nil)
        let tallFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), tallPath, nil)
        let lines = (CTFrameGetLines(tallFrame) as? [CTLine]) ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(tallFrame, CFRange(location: 0, length: 0), &origins)

        let ns = text as NSString
        var lineStrings: [String] = []
        var ink: CGRect?
        for (i, line) in lines.enumerated() {
            let r = CTLineGetStringRange(line)
            lineStrings.append(ns.substring(with: NSRange(location: r.location, length: r.length))
                .trimmingCharacters(in: .newlines))
            let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            guard !b.isNull, !b.isEmpty else { continue }
            // path座標（左下原点）→ box左上原点
            let top = tallHeight - (origins[i].y + b.maxY)
            let r2 = CGRect(x: origins[i].x + b.minX, y: top, width: b.width, height: b.height)
            ink = ink.map { $0.union(r2) } ?? r2
        }
        let inkRect = ink ?? .zero
        let inkInImage = PixelRect(x: rect.x + Double(inkRect.minX), y: rect.y + Double(inkRect.minY),
                                   width: Double(inkRect.width), height: Double(inkRect.height))
        return .measured(LayoutMeasurement(lines: lineStrings, allGlyphsPlaced: allPlaced, inkBounds: inkInImage))
    }
}
#endif
