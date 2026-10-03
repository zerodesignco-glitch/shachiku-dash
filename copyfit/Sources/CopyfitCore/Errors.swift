import Foundation

/// 入力/実行エラー（終了コード2）。メッセージは日本語で、何を直せばよいかを含める。
public enum CopyfitError: Error, Equatable, CustomStringConvertible {
    case invalidInput(String)
    case pathEscape(String)
    case limitExceeded(String)
    case io(String)

    public var description: String {
        switch self {
        case .invalidInput(let m): return "入力エラー: \(m)"
        case .pathEscape(let m): return "パス安全性エラー: \(m)"
        case .limitExceeded(let m): return "上限超過: \(m)"
        case .io(let m): return "入出力エラー: \(m)"
        }
    }
}

/// 巨大画像・過剰入力に対する上限（暫定値。docs/KNOWN_LIMITATIONS.md参照）。
public struct Limits: Sendable {
    public var maxPixels: Int = 40_000_000
    public var maxFileBytes: Int = 100 * 1024 * 1024
    public var maxAssets: Int = 300
    public var maxCopyBytes: Int = 10 * 1024 * 1024

    public init() {}
}
