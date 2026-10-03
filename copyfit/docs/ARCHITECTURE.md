# Architecture

```
InputLoader（Auditor）→ ManifestLoader / CopyLoader / RulesetLoader
                       → ImageInspector（全OS共通の構造検査）＋ ImageIODecodeCheck（macOSのみ）
                       → OCRProvider（VisionOCR / Unavailable / Fixed）
                       → TextMeasurer（CoreTextMeasurer / Unavailable / Fixed）
                       → RuleEngine（純粋関数）→ ReportWriter（JSON）/ HTMLRenderer
```

| target | 役割 | 依存 |
|---|---|---|
| `CopyfitCore` | モデル、入力の読み込み、PNG/JPEGヘッダの解析、path guard、RuleEngine、レポート出力 | Foundationのみ（Linuxでもbuild/test可能） |
| `CopyfitMac` | Vision OCR、CoreText計測、ImageIOデコード。いずれも `#if canImport` で囲み、他OSではunavailableを返す | CopyfitCore + OSフレームワーク |
| `copyfit` | CLI（引数解析、終了コード、日本語のエラー表示） | 上記2つ |

外部依存（SwiftPMパッケージ、SDK、ネットワークAPI）はありません。SHA-256とCRC32も自前で実装しています。

## 設計の要点

- **RuleEngineは決定的です。** `RuleInput` を受け取って `[Finding]` を返すだけの関数で、I/OやOSのAPIを一切呼びません。同じ入力からは同じ順序の結果が返ります。
- **OCRと計測は差し替えられる作りです。** core testでは `FixedOCR` や `FixedMeasurer` で観測値を注入します。VisionやCoreTextを実機で動かすテストは `CopyfitIntegrationTests` に分けています（OSやrevisionによって結果が変わり得るためです）。
- **座標系は1か所で扱います。** 内部の座標はすべて、向きを正規化した画像の左上を原点とするpixel値です。Visionの正規化座標（左下原点）との相互変換は `CoordinateConversion` にまとめています。EXIF orientationが5〜8の場合は幅と高さを入れ替えます。
- **入力を変更しません。** 入力は読むだけです。開始時のhashを記録し、終了時に再計算して比べます。レポートに入れる画像はhash名でコピーします。出力先は、空のdirectoryか、copyfitが作ったdirectory（marker付き）に限ります。
- **状態とルールの根拠を明示します。** 状態は `PASS / FAIL / WARN / UNKNOWN` の4種類です。各Findingには根拠の種類として `apple-official / project-rule / heuristic / tool-meta` を付けます。

## ADR-001: Swift Package CLIを採用

- 状況: 指示書の既定案はmacOS上のSwift CLIです。このrepository（`shachiku-dash`）は公開ページ用の静的サイトで、流用できる画像処理・検証・CLIのコードはありません。
- 決定: Swift Packageで、CLI、core library、テスト、ローカルHTMLレポートを構成します。macOS GUIとiOS版は作りません。deployment targetは **macOS 13** とします（`VNRecognizeTextRequest` の `.accurate`、`supportedRecognitionLanguages()`、CoreTextの `CTLineGetBoundsWithOptions` がすべて使えるため）。
- 根拠: ImageIO、Vision、CoreTextをOS標準のまま使えるため、オフラインでOCRができ、外部SDKも不要です。batch処理とCIに向いています。
- 影響: 入力にmanifestの準備が必要です。GUIでの領域指定は、内部CLIを使った後で改めて評価します。

## ADR-002: macOS非依存のcoreと、Linuxでの開発検証

- 状況: 初回の実装環境はLinuxのコンテナで、VisionとCoreTextがありません。
- 決定: 判定ロジック、入力の読み込み、レポート出力はFoundationだけで書き、Linuxでもテストできるようにしました。OS依存の部分は `CopyfitMac` に閉じ込めています。macOS adapterのbuildと実機テストは、GitHub Actionsの `macos-15` jobで確認します（`.github/workflows/copyfit.yml`）。
- 影響: Linux上では、OCRとfit計測の判定は常にUNKNOWNになります。PASSにはなりません。
