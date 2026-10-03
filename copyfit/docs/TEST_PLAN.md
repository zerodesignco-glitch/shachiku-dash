# Test Plan と結果

## テスト構成

| 区分 | 場所 | 内容 |
|---|---|---|
| 確定ルールのunit test | `Tests/CopyfitCoreTests/RuleEngineTests.swift` | FIT001の1px境界、metadata未検証時の扱い、font欠落、SAFE001、OCR照合、ASSET/IMAGE/RULE/COPY/BREAK、allowlistの期限、終了コード、決定性 |
| 入力 | `InputTests.swift` | PNG/JPEGのヘッダ、alpha、破損、上限、EXIF回転、拡張子の不一致、CSV（RFC 4180、実改行、文字列の`\n`、BOM、重複）、manifestの検証、path guard（`..`、絶対path、symlink）、SHA-256の既知値、Vision座標の変換 |
| fixture結合 | `FixtureAndReportTests.swift` | `Fixtures/cases/*`（28件）と `Fixtures/demo12` を実ファイルとしてAuditorに通し、`expected.json` と照合。確定ルールは**見逃しと誤検知の両方**を検出する（multisetで完全一致） |
| report | 同上 | HTMLのescape（悪意ある文字列）、外部参照とscriptがないこと、JSONとHTMLの整合、golden report（`Golden/`、更新は `UPDATE_GOLDEN=1`）、入力hashが変わらないこと、出力先の保護 |
| heuristicの評価 | `TextRulesTests.swift` | 改行heuristicのラベル付き44サンプル（不良20、正常24）で、precisionとrecallを算出 |
| 性能 | `FixtureAndReportTests.swift` | demo12（11枚）と100枚で、クラッシュせず時間内に終わること |
| CLI | `Tests/CopyfitIntegrationTests/CLITests.swift` | ビルドしたバイナリで、終了コード0/1/2/3、`--json`、`rulesets`、`--version` を確認 |
| OSのOCRとCoreText | `PlatformAdapterTests.swift` | macOSのみ：Visionで合成見出しを読む（座標の上下を含む）、ImageIO、CoreTextの境界とfont欠落。それ以外のOSではunavailableを確認 |

## fixture（すべて合成）

生成スクリプトは `scripts/make_fixtures.py` です（Pillowが必要。描画fontはIPAGothicとDejaVu Sans）。

**demo12**：3 locale（ja-JP / en-US / de-DE）× 2 target（iphone-6.9 / ipad-13）× 2 slot。次の不備を意図的に混ぜています。

- 1件の欠落
- 1px違い
- 透明PNG
- 日本語の行頭禁則（2件）
- ドイツ語の長い見出しが画像の外へはみ出す
- 低コントラスト（OCRが不確実）
- badgeの同一文言（COPY002）

**cases**（28件）

| case | 期待する結果 |
|---|---|
| normal-pass / normal-pass-ja-de | 確定ルールでFAILもWARNも出ない（誤検知の確認） |
| missing-locale / missing-slot / missing-file | ASSET001 FAIL |
| explicit-fallback | 欠落はあるが明示fallbackがあるためPASS |
| duplicate-asset | ASSET002 FAIL（どちらも選ばない） |
| swapped-orientation | IMAGE001 FAIL（縦横逆） |
| off-by-1px | IMAGE001 FAIL ×2（manifestの指定、Appleの許容寸法） |
| alpha-png | IMAGE002 FAIL |
| corrupt-png | IMAGE003 FAIL |
| huge-image | 終了コード2（ヘッダが48MPを示し、デコード前に拒否） |
| jpeg-exif-rotated | orientation 6を正規化し、1290×2796として通る |
| ext-mismatch | IMAGE001 WARN |
| unknown-target / no-ruleset | RULE001 UNKNOWN |
| expired-ruleset | RULE001 WARN |
| copy-missing-key / copy-empty / copy-duplicate | COPY001 FAIL |
| mockup-forbidden | SAFE001 WARN（metadata未検証） |
| kinsoku-line-start | BREAK001 WARN |
| missing-font-placeholder | FIT001 UNKNOWN（PASSにならない） |
| malicious-strings | HTMLでescapeされる |
| path-traversal | 終了コード2 |
| low-confidence-ocr | TEXT001 UNKNOWN |
| ocr-mismatch | TEXT001 WARN |
| ocr-edge-overflow | FIT002 WARN（boxからのはみ出しと画像の端）、TEXT001 WARN |

絵文字と結合文字、英語の長い単語、ドイツ語の伸長、日本語の長文、boxからのはみ出しは、`RuleEngineTests` と `TextRulesTests` で固定の観測・計測値を注入して検証しています。CoreTextの実計測はmacOSのjobで行います。

## 受入基準と結果

| 基準 | 結果 |
|---|---|
| 確定ルール（寸法、欠落、schema、形式）でfixtureの誤判定0 | **達成**（Linux、28 case + demo12。見逃し0、誤検知0） |
| FIT001の1px余裕と1px不足の境界 | **達成**（注入した計測値によるunit test）。CoreTextの実計測による境界テストはmacOSのCIで実行 |
| heuristicのprecision 90%以上 | 改行heuristic：**precision 0.950 / recall 0.950**（TP 19 / FP 1 / FN 1 / TN 23）。誤警告は「通勤を、／速く。」（2文字の短い最終行）、見逃しは「…erfassen und／auswerten」（1語だけの最終行が直前の行の25%より長い）。目標を満たしたため既定でON。OCRのheuristic（TEXT001/FIT002）は、実機OCRのデータセットがないため**未評価**（UNKNOWN率も未測定） |
| 12画像を約30秒（選定Mac） | **選定Macでは未測定**。GitHub Actions macos-15（仮想マシン）でVision＋CoreText有効時、demo12（11枚）がrelease CLIで**11.2秒**（FAIL 4 / WARN 14 / UNKNOWN 27 / PASS 70、終了コード1）。WARNの内訳の目視確認はまだしていない。Linux（4 vCPU、OCRとCoreTextなし）ではdemo12が0.18秒、release CLIで0.05秒 |
| 100画像でクラッシュやOOMがないこと | Linux（OCRなし）で100枚0.82秒、問題なし。Vision有効時のメモリ量は未測定（並列数は4に制限） |
| HTMLとJSONの整合、offline、入力hash不変、全終了コード | **達成**（自動テスト） |
| schema migration | schemaVersion 1のみ。未対応のversionは明示的なエラーにする（migrationの対象はまだない） |
| locale別の改行、OCR座標の変換 | 達成（unit test。Visionの実座標はmacOSのCIで確認） |

## 実行環境と記録（2026-10-03）

- 環境：Ubuntu 24.04（コンテナ）、Swift 6.0.3（Ubuntu archiveの `swiftlang` パッケージ）、4 vCPU
- コマンド：`swift build -Xswiftc -warnings-as-errors`、`swift build -c release`、`swift test`
- 結果：62 tests、失敗0（macOS専用のテスト3件は、この環境ではコンパイル対象外。代わりにunavailableを確認する1件を実行）
- macOS（GitHub Actions macos-15 / macOS 15.7 / Swift 6.1.2、2026-10-03）：debug/releaseとも `-warnings-as-errors` でbuild成功。Visionは合成見出しを「Make every commute」「faster.」としてconfidence 1.0で読み、座標も上下反転なし（y≈215〜430）。OCRなしの性能はdemo12が0.37秒、100枚が1.40秒。初回はCoreTextの境界テストの前提（ink幅＝折返し幅）が誤っていたため修正した
