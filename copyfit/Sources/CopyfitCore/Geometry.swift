import Foundation

/// 向き正規化後の画像の左上原点pixel矩形（x, y, width, height）。
public struct PixelRect: Codable, Equatable, Hashable, CustomStringConvertible, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// manifestの`[x, y, width, height]`形式。
    public init(array: [Double]) throws {
        guard array.count == 4 else {
            throw CopyfitError.invalidInput("矩形は[x, y, width, height]の4要素で指定してください: \(array)")
        }
        self.init(x: array[0], y: array[1], width: array[2], height: array[3])
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Double] = []
        while !container.isAtEnd { values.append(try container.decode(Double.self)) }
        try self.init(array: values)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(contentsOf: [x, y, width, height])
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public var description: String { "[\(fmt(x)), \(fmt(y)), \(fmt(width)), \(fmt(height))]" }

    public func intersects(_ other: PixelRect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    public func contains(_ other: PixelRect, tolerance: Double = 0) -> Bool {
        other.minX >= minX - tolerance && other.minY >= minY - tolerance
            && other.maxX <= maxX + tolerance && other.maxY <= maxY + tolerance
    }

    public func containsPoint(x px: Double, y py: Double) -> Bool {
        px >= minX && px <= maxX && py >= minY && py <= maxY
    }

    public func insetBy(_ d: Double) -> PixelRect {
        PixelRect(x: x + d, y: y + d, width: width - 2 * d, height: height - 2 * d)
    }

    public func union(_ other: PixelRect) -> PixelRect {
        let nx = min(minX, other.minX), ny = min(minY, other.minY)
        return PixelRect(x: nx, y: ny, width: max(maxX, other.maxX) - nx, height: max(maxY, other.maxY) - ny)
    }

    /// 画像範囲内かつ正の大きさか。
    public func isValid(inWidth w: Int, height h: Int) -> Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0 && maxX <= Double(w) && maxY <= Double(h)
    }

    /// 自分の外へはみ出している量（各辺の最大値, px）。
    public func overflow(of inner: PixelRect) -> Double {
        max(0, minX - inner.minX, minY - inner.minY, inner.maxX - maxX, inner.maxY - maxY)
    }
}

/// 座標変換はここに集約する。
public enum CoordinateConversion {
    /// Visionの正規化座標（左下原点, 0...1）を、向き正規化済み画像の左上原点pixelへ変換する。
    public static func visionNormalizedToPixel(
        x: Double, y: Double, width: Double, height: Double,
        imageWidth: Int, imageHeight: Int
    ) -> PixelRect {
        let w = Double(imageWidth), h = Double(imageHeight)
        return PixelRect(x: x * w, y: (1 - y - height) * h, width: width * w, height: height * h)
    }

    /// 左上原点pixelをVisionの正規化座標（左下原点）へ戻す（regionOfInterest用）。
    public static func pixelToVisionNormalized(_ r: PixelRect, imageWidth: Int, imageHeight: Int)
        -> (x: Double, y: Double, width: Double, height: Double)
    {
        let w = Double(imageWidth), h = Double(imageHeight)
        return (r.x / w, 1 - (r.y + r.height) / h, r.width / w, r.height / h)
    }

    /// EXIF orientation 5〜8は90度回転を含むため、表示上の幅と高さが入れ替わる。
    public static func orientedSize(width: Int, height: Int, exifOrientation: Int) -> (Int, Int) {
        (5...8).contains(exifOrientation) ? (height, width) : (width, height)
    }
}

func fmt(_ v: Double) -> String {
    v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
}
