import XCTest
@testable import CopyfitCore

final class TextRulesTests: XCTestCase {
    func rules(_ lines: [String], _ locale: String = "ja-JP", phrases: [String] = []) -> [String] {
        LineBreakRules.check(lines: lines, locale: locale, noBreakPhrases: phrases).map(\.ruleID)
    }

    func testKinsoku() {
        XCTAssertEqual(rules(["記録し", "、振り返る"]), ["BREAK001"])
        XCTAssertEqual(rules(["使い方は「", "かんたん」です"]), ["BREAK001"])
        XCTAssertEqual(rules(["小さな", "ゃ行頭がだめな例"]), ["BREAK001"])
        XCTAssertEqual(rules(["毎日の通勤を、", "もっと速く。"]), [])
        XCTAssertEqual(rules(["Fast and simple", ", really"], "en-US"), ["BREAK001"])
    }

    func testNoBreakPhrase() {
        XCTAssertEqual(rules(["残業時", "間を記録する"], phrases: ["残業時間"]), ["BREAK001"])
        XCTAssertEqual(rules(["残業時間を", "記録する"], phrases: ["残業時間"]), [])
        XCTAssertEqual(rules(["Now on iPhone 17 Pro", "Max and more devices"], "en-US", phrases: ["Pro Max"]), ["BREAK001"])
    }

    func testNumberUnitAndOrphan() {
        XCTAssertEqual(rules(["最大50", "%オフで買える"]).contains("BREAK002"), true)
        XCTAssertEqual(rules(["Save up to 30", "min every single day"], "en-US"), ["BREAK002"])
        XCTAssertEqual(rules(["Save 30 min", "every single day"], "en-US"), [])
        XCTAssertEqual(rules(["毎日の通勤をもっと速", "く"]), ["BREAK002"])
        XCTAssertEqual(rules(["Jeden Arbeitsweg schneller und", "machen"], "de-DE"), ["BREAK002"])
        XCTAssertEqual(rules(["Überstunden automatisch", "erfassen"], "de-DE"), [])
    }

    func testNormalizationKeepsMeaning() {
        // NFD（か + 濁点）とNFC（が）は同一視する
        XCTAssertEqual(TextNormalizer.normalizeForComparison("か\u{3099}んばる", locale: "ja-JP"),
                       TextNormalizer.normalizeForComparison("がんばる", locale: "ja-JP"))
        // 濁点の有無・句読点・数字は区別する
        XCTAssertNotEqual(TextNormalizer.normalizeForComparison("はんばる", locale: "ja-JP"),
                          TextNormalizer.normalizeForComparison("がんばる", locale: "ja-JP"))
        XCTAssertNotEqual(TextNormalizer.normalizeForComparison("Save 30%", locale: "en-US"),
                          TextNormalizer.normalizeForComparison("Save 30", locale: "en-US"))
        // 空白/改行はlatinでは1つの空白、CJKでは除去
        XCTAssertEqual(TextNormalizer.normalizeForComparison(" Make  every\ncommute ", locale: "en-US"), "Make every commute")
        XCTAssertEqual(TextNormalizer.normalizeForComparison("毎日の 通勤を、\nもっと", locale: "ja-JP"), "毎日の通勤を、もっと")
        // 絵文字・ZWJ・結合文字は保持
        let family = "Family 👨‍👩‍👧 é"
        XCTAssertEqual(TextNormalizer.normalizeForComparison(family, locale: "en-US"), family.precomposedStringWithCanonicalMapping)
        XCTAssertNotEqual(TextNormalizer.normalizeForComparison("👨‍👩‍👧", locale: "en-US"),
                          TextNormalizer.normalizeForComparison("👨👩👧", locale: "en-US"))
    }

    func testDiffSummary() {
        XCTAssertEqual(TextNormalizer.diffSummary(expected: "Hello world", actual: "Hello wor"), "位置9: 期待「ld」 / OCR「」")
    }
}

/// heuristic（BREAK001/002）の評価。正常/不良のラベル付き行セットでprecision/recallを測る。
/// 結果はdocs/TEST_PLAN.mdに転記する。precision 90%未満ならデフォルトOFFにする判断材料。
final class HeuristicEvaluationTests: XCTestCase {
    struct Sample { let lines: [String]; let locale: String; let bad: Bool }

    static let samples: [Sample] = [
        // 不良（改行品質に問題あり）
        .init(lines: ["記録し", "、振り返る"], locale: "ja-JP", bad: true),
        .init(lines: ["もっと速く", "。"], locale: "ja-JP", bad: true),
        .init(lines: ["「通勤", "」を変える"], locale: "ja-JP", bad: true),
        .init(lines: ["使い方は「", "かんたん」"], locale: "ja-JP", bad: true),
        .init(lines: ["自動で記録", "っていく"], locale: "ja-JP", bad: true),
        .init(lines: ["最大50", "%オフ"], locale: "ja-JP", bad: true),
        .init(lines: ["毎日の通勤をもっと速", "く"], locale: "ja-JP", bad: true),
        .init(lines: ["残業時間を自動で記録しま", "す"], locale: "ja-JP", bad: true),
        .init(lines: ["月額480", "円から"], locale: "ja-JP", bad: true),
        .init(lines: ["データは端末内に保存", "ー"], locale: "ja-JP", bad: true),
        .init(lines: ["Save up to 30", "min a day"], locale: "en-US", bad: true),
        .init(lines: ["Track every commute and", "more"], locale: "en-US", bad: true),
        .init(lines: ["Plans from $", "4.99"], locale: "en-US", bad: true),
        .init(lines: ["Fast and simple", ", really"], locale: "en-US", bad: true),
        .init(lines: ["Store up to 10", "GB offline"], locale: "en-US", bad: true),
        .init(lines: ["Your overtime, tracked automatically", "now"], locale: "en-US", bad: true),
        .init(lines: ["Jeden Arbeitsweg schneller und", "machen"], locale: "de-DE", bad: true),
        .init(lines: ["Bis zu 30", "Min sparen"], locale: "de-DE", bad: true),
        .init(lines: ["Überstunden automatisch erfassen und", "auswerten"], locale: "de-DE", bad: true),
        .init(lines: ["Spare bis zu 50", "% jeden Monat"], locale: "de-DE", bad: true),
        // 正常
        .init(lines: ["毎日の通勤を、", "もっと速く。"], locale: "ja-JP", bad: false),
        .init(lines: ["残業時間を", "自動で記録"], locale: "ja-JP", bad: false),
        .init(lines: ["グラフで", "振り返る"], locale: "ja-JP", bad: false),
        .init(lines: ["データは", "端末内だけに保存"], locale: "ja-JP", bad: false),
        .init(lines: ["最大50%オフ", "今だけのキャンペーン"], locale: "ja-JP", bad: false),
        .init(lines: ["「通勤」を", "変えよう"], locale: "ja-JP", bad: false),
        .init(lines: ["通知で", "帰る時間を知らせる"], locale: "ja-JP", bad: false),
        .init(lines: ["月額480円から", "はじめられる"], locale: "ja-JP", bad: false),
        .init(lines: ["一目でわかる", "今日の実績"], locale: "ja-JP", bad: false),
        .init(lines: ["シンプルな", "ダッシュボード"], locale: "ja-JP", bad: false),
        .init(lines: ["Make every commute", "faster."], locale: "en-US", bad: false),
        .init(lines: ["Track overtime", "automatically"], locale: "en-US", bad: false),
        .init(lines: ["Save 30 min", "every day"], locale: "en-US", bad: false),
        .init(lines: ["Plans from $4.99", "per month"], locale: "en-US", bad: false),
        .init(lines: ["Your data stays", "on your device"], locale: "en-US", bad: false),
        .init(lines: ["See your week", "at a glance"], locale: "en-US", bad: false),
        .init(lines: ["Überstunden automatisch", "erfassen"], locale: "de-DE", bad: false),
        .init(lines: ["Jeden Arbeitsweg", "schneller machen"], locale: "de-DE", bad: false),
        .init(lines: ["Spare bis zu 50 %", "jeden Monat"], locale: "de-DE", bad: false),
        .init(lines: ["Deine Daten bleiben", "auf dem Gerät"], locale: "de-DE", bad: false),
        // 判定が難しい例（意図的に含め、heuristicの限界を測る）
        .init(lines: ["Fast.", "Simple.", "Yours."], locale: "en-US", bad: false),
        .init(lines: ["通勤を、", "速く。"], locale: "ja-JP", bad: false),
        .init(lines: ["Pendeln mit", "Plan"], locale: "de-DE", bad: false),
        .init(lines: ["Try it", "free"], locale: "en-US", bad: false),
    ]

    func testPrecisionRecall() {
        var tp = 0, fp = 0, fn = 0, tn = 0
        var misses: [String] = []
        for s in Self.samples {
            let flagged = !LineBreakRules.check(lines: s.lines, locale: s.locale).isEmpty
            switch (flagged, s.bad) {
            case (true, true): tp += 1
            case (true, false): fp += 1; misses.append("誤警告: \(s.lines)")
            case (false, true): fn += 1; misses.append("見逃し: \(s.lines)")
            case (false, false): tn += 1
            }
        }
        let precision = Double(tp) / Double(max(1, tp + fp))
        let recall = Double(tp) / Double(max(1, tp + fn))
        print("HEURISTIC_EVAL samples=\(Self.samples.count) bad=\(tp + fn) good=\(fp + tn) TP=\(tp) FP=\(fp) FN=\(fn) TN=\(tn) precision=\(String(format: "%.3f", precision)) recall=\(String(format: "%.3f", recall))")
        for m in misses { print("HEURISTIC_EVAL \(m)") }
        XCTAssertGreaterThanOrEqual(Self.samples.filter(\.bad).count, 20)
        XCTAssertGreaterThanOrEqual(Self.samples.filter { !$0.bad }.count, 20)
        XCTAssertGreaterThanOrEqual(precision, 0.9, "警告precisionが目標90%未満")
    }
}
