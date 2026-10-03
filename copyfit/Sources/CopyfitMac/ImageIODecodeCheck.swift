#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO

/// ImageIOで実際にデコードできるかを確認する（構造検査に加えた二重確認）。
enum ImageIODecodeCheck {
    @Sendable static func problem(at url: URL) -> String? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else {
            return "ImageIOで画像を開けません"
        }
        let status = CGImageSourceGetStatus(src)
        guard status == .statusComplete else {
            return "ImageIOの読み込み状態が不完全です（status \(status.rawValue)）"
        }
        guard CGImageSourceCreateImageAtIndex(src, 0, opts) != nil else {
            return "ImageIOで画像をデコードできません"
        }
        return nil
    }
}
#endif
