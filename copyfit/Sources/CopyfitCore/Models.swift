import Foundation

public let copyfitToolVersion = "0.1.0"
public let reportSchemaVersion = 1

/// 検査結果のステータス。UNKNOWNは「検査不能」であり、決してPASS扱いしない。
public enum Status: String, Codable, CaseIterable, Comparable, Sendable {
    case pass = "PASS"
    case warn = "WARN"
    case unknown = "UNKNOWN"
    case fail = "FAIL"

    var severity: Int {
        switch self {
        case .pass: return 0
        case .warn: return 1
        case .unknown: return 2
        case .fail: return 3
        }
    }

    public static func < (lhs: Status, rhs: Status) -> Bool { lhs.severity < rhs.severity }
}

/// ルールの根拠の種類。Apple公式要件・プロジェクト設計ルール・heuristicをreport上で区別する。
public enum RuleBasis: String, Codable, Sendable {
    case appleOfficial = "apple-official"
    case projectRule = "project-rule"
    case heuristic = "heuristic"
    case toolMeta = "tool-meta"
}

public struct AssetKey: Hashable, Codable, Comparable, CustomStringConvertible, Sendable {
    public var locale: String
    public var target: String
    public var slot: String

    public init(locale: String, target: String, slot: String) {
        self.locale = locale
        self.target = target
        self.slot = slot
    }

    public var description: String { "\(locale)/\(target)/\(slot)" }

    public static func < (lhs: AssetKey, rhs: AssetKey) -> Bool {
        (lhs.locale, lhs.target, lhs.slot) < (rhs.locale, rhs.target, rhs.slot)
    }
}

public enum ImageFormat: String, Codable, Sendable {
    case png
    case jpeg
    case unknown
}

/// 向きを正規化した後の画像の事実。座標はすべてこの寸法の左上原点pixel。
public struct AssetFacts: Codable, Equatable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var format: ImageFormat
    public var hasAlphaChannel: Bool
    public var orientation: Int
    public var fileHash: String
    public var fileSizeBytes: Int
    public var colorDescription: String
    /// 構造検査（chunk CRC / marker）またはOSデコードで問題が見つかった場合の説明。
    public var integrityProblem: String?
    public var extensionMismatch: Bool

    public init(pixelWidth: Int, pixelHeight: Int, format: ImageFormat, hasAlphaChannel: Bool,
                orientation: Int = 1, fileHash: String = "", fileSizeBytes: Int = 0,
                colorDescription: String = "", integrityProblem: String? = nil,
                extensionMismatch: Bool = false) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.format = format
        self.hasAlphaChannel = hasAlphaChannel
        self.orientation = orientation
        self.fileHash = fileHash
        self.fileSizeBytes = fileSizeBytes
        self.colorDescription = colorDescription
        self.integrityProblem = integrityProblem
        self.extensionMismatch = extensionMismatch
    }
}

public struct OCRObservation: Codable, Equatable, Sendable {
    public var text: String
    /// 画像左上原点のpixel矩形（Vision座標からの変換はGeometryに集約）。
    public var boundingBox: PixelRect
    public var confidence: Double
    public var language: String?
    public var engineRevision: String

    public init(text: String, boundingBox: PixelRect, confidence: Double,
                language: String? = nil, engineRevision: String) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.language = language
        self.engineRevision = engineRevision
    }
}

public enum OCROutcome: Equatable, Sendable {
    case observations([OCRObservation])
    case unavailable(String)
    case unsupportedLanguage(String)
    case failed(String)
}

public struct Finding: Codable, Equatable, Sendable {
    public var ruleID: String
    public var ruleVersion: Int
    public var basis: RuleBasis
    public var assetKey: AssetKey?
    public var regionID: String?
    public var status: Status
    public var message: String
    public var evidence: [String]
    public var measuredValue: String?
    public var expectedValue: String?
    public var remediation: String?

    public init(ruleID: String, ruleVersion: Int = 1, basis: RuleBasis, assetKey: AssetKey?,
                regionID: String? = nil, status: Status, message: String, evidence: [String] = [],
                measuredValue: String? = nil, expectedValue: String? = nil, remediation: String? = nil) {
        self.ruleID = ruleID
        self.ruleVersion = ruleVersion
        self.basis = basis
        self.assetKey = assetKey
        self.regionID = regionID
        self.status = status
        self.message = message
        self.evidence = evidence
        self.measuredValue = measuredValue
        self.expectedValue = expectedValue
        self.remediation = remediation
    }
}

public struct Summary: Codable, Equatable, Sendable {
    public var assetsDeclared: Int
    public var assetsInspected: Int
    public var pass: Int
    public var fail: Int
    public var warn: Int
    public var unknown: Int

    public init(findings: [Finding], assetsDeclared: Int, assetsInspected: Int) {
        self.assetsDeclared = assetsDeclared
        self.assetsInspected = assetsInspected
        pass = findings.filter { $0.status == .pass }.count
        fail = findings.filter { $0.status == .fail }.count
        warn = findings.filter { $0.status == .warn }.count
        unknown = findings.filter { $0.status == .unknown }.count
    }
}

/// HTML overlay用の画像単位の情報。
public struct AssetReportEntry: Codable, Equatable, Sendable {
    public var key: AssetKey
    public var path: String
    public var facts: AssetFacts?
    public var reportImagePath: String?
    public var regions: [RegionOverlay]
    public var forbiddenRects: [ForbiddenRect]
    public var ocrObservations: [OCRObservation]
    public var ocrNote: String?
}

public struct RegionOverlay: Codable, Equatable, Sendable {
    public var id: String
    public var rect: PixelRect
    public var expectedCopy: String?
    public var measuredInkBounds: PixelRect?
}

public struct AuditReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var toolVersion: String
    public var rulesetVersion: String
    public var rulesetCheckedAt: String?
    public var osVersion: String
    public var generatedAt: String
    public var ocrEngine: String
    public var textMeasurer: String
    public var inputHashes: [String: String]
    public var summary: Summary
    public var findings: [Finding]
    public var assets: [AssetReportEntry]
    public var disclaimer: String
}

public enum ExitCode: Int32 {
    case ok = 0
    case fail = 1
    case inputError = 2
    case strictUnresolved = 3

    public static func from(summary: Summary, strict: Bool) -> ExitCode {
        if summary.fail > 0 { return .fail }
        if strict && (summary.warn > 0 || summary.unknown > 0) { return .strictUnresolved }
        return .ok
    }
}
