import Foundation

/// Appleのスクショ仕様を転記したversion付きローカルruleset。実行中に自動fetchしない。
public struct Ruleset: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var rulesetID: String
    public var effectiveVersion: String
    public var checkedAt: String
    public var maxAgeDays: Int
    public var sourceURLs: [String]
    public var notes: String?
    public var acceptedFormats: [String]
    public var alphaAllowed: Bool
    public var maxScreenshotsPerSet: Int?
    public var targets: [Target]

    public struct Target: Codable, Equatable, Sendable {
        public var id: String
        public var displayName: String
        public var allowedPixelSizes: [[Int]]

        public func allows(width: Int, height: Int) -> Bool {
            allowedPixelSizes.contains { $0 == [width, height] }
        }
    }

    public func target(_ id: String) -> Target? { targets.first { $0.id == id } }

    /// checkedAtからの経過日数（日付が読めなければnil）。
    public func ageInDays(now: Date) -> Int? {
        guard let checked = parseDay(checkedAt) else { return nil }
        return Int(floor(now.timeIntervalSince(checked) / 86_400))
    }
}

public enum RulesetLoader {
    public static func load(data: Data) throws -> Ruleset {
        do {
            let r = try JSONDecoder().decode(Ruleset.self, from: data)
            guard r.schemaVersion == 1 else {
                throw CopyfitError.invalidInput("rulesetの未対応schemaVersion: \(r.schemaVersion)")
            }
            return r
        } catch let e as CopyfitError {
            throw e
        } catch {
            throw CopyfitError.invalidInput("rulesetを読めません: \(error)")
        }
    }

    /// 同梱rulesetをIDで探す。見つからなければnil（RULE001 UNKNOWNとして扱う）。
    public static func bundled(id: String) -> Ruleset? {
        guard id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              let url = Bundle.module.url(forResource: id, withExtension: "json", subdirectory: "Rulesets")
                ?? Bundle.module.url(forResource: "Rulesets/\(id)", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? load(data: data)
    }

    public static func bundledIDs() -> [String] {
        guard let dir = Bundle.module.url(forResource: "Rulesets", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }
}
