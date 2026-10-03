import CopyfitCore
import Foundation

/// 実行OSで利用できるadapterを返す。macOS以外ではOCR/fit計測はunavailable（判定はUNKNOWN）になる。
public enum PlatformAdapters {
    public static func ocr() -> OCRProvider {
        #if canImport(Vision)
        return VisionOCR()
        #else
        return UnavailableOCR(reason: "このOSではOS標準OCR（Vision）を利用できません")
        #endif
    }

    public static func measurer() -> TextMeasurer {
        #if canImport(CoreText) && canImport(CoreGraphics)
        return CoreTextMeasurer()
        #else
        return UnavailableMeasurer(reason: "このOSではCoreTextを利用できません")
        #endif
    }

    public static func decodeCheck() -> (@Sendable (URL) -> String?)? {
        #if canImport(ImageIO)
        return ImageIODecodeCheck.problem(at:)
        #else
        return nil
        #endif
    }
}
