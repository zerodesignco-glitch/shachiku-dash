import Foundation

/// OS標準OCRのadapter。core testでは固定観測を注入する。
public protocol OCRProvider: Sendable {
    var engineDescription: String { get }
    /// 利用可能な認識言語（BCP47）。取得できない場合nil。
    func supportedLanguages() -> [String]?
    func recognize(imageURL: URL, facts: AssetFacts, languages: [String]) throws -> [OCRObservation]
}

/// 期待文言を指定font/boxへレイアウトするadapter（macOSではCoreText）。
public protocol TextMeasurer: Sendable {
    var engineDescription: String { get }
    func measure(text: String, metadata: LayoutMetadata, rect: PixelRect, locale: String) -> MeasureOutcome
}

public enum MeasureOutcome: Equatable, Sendable {
    case measured(LayoutMeasurement)
    /// 指定fontが見つからない（無断fallbackしない）。
    case fontMissing(String)
    case unavailable(String)
}

public struct LayoutMeasurement: Equatable, Sendable {
    /// 実際に組まれた各行（CoreTextの改行結果）。
    public var lines: [String]
    /// 指定boxの高さ内に全glyphが配置できたか。
    public var allGlyphsPlaced: Bool
    /// 画像座標でのink範囲（glyph path bounds）。
    public var inkBounds: PixelRect

    public init(lines: [String], allGlyphsPlaced: Bool, inkBounds: PixelRect) {
        self.lines = lines
        self.allGlyphsPlaced = allGlyphsPlaced
        self.inkBounds = inkBounds
    }
}

/// OCRを持たない環境（Linux等）用。常にunavailableを返し、TEXT001はUNKNOWNになる。
public struct UnavailableOCR: OCRProvider {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var engineDescription: String { "none (\(reason))" }
    public func supportedLanguages() -> [String]? { nil }
    public func recognize(imageURL: URL, facts: AssetFacts, languages: [String]) throws -> [OCRObservation] {
        throw CopyfitError.io(reason)
    }
}

public struct UnavailableMeasurer: TextMeasurer {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var engineDescription: String { "none (\(reason))" }
    public func measure(text: String, metadata: LayoutMetadata, rect: PixelRect, locale: String) -> MeasureOutcome {
        .unavailable(reason)
    }
}

/// テスト・再現用: 事前に記録した観測を返す。
public struct FixedOCR: OCRProvider {
    public var observations: [String: [OCRObservation]]
    public var languages: [String]?
    public init(observations: [String: [OCRObservation]], languages: [String]? = ["ja-JP", "en-US", "de-DE"]) {
        self.observations = observations
        self.languages = languages
    }
    public var engineDescription: String { "fixed-observations" }
    public func supportedLanguages() -> [String]? { languages }
    public func recognize(imageURL: URL, facts: AssetFacts, languages: [String]) throws -> [OCRObservation] {
        observations[imageURL.lastPathComponent] ?? observations[imageURL.path] ?? []
    }
}

public struct FixedMeasurer: TextMeasurer {
    public var results: [String: MeasureOutcome]
    public init(results: [String: MeasureOutcome]) { self.results = results }
    public var engineDescription: String { "fixed-measurements" }
    public func measure(text: String, metadata: LayoutMetadata, rect: PixelRect, locale: String) -> MeasureOutcome {
        results[text] ?? .unavailable("no fixed measurement")
    }
}
