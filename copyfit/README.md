# copyfit — App Store Screenshot Copyfit Auditor（内部MVP）

完成済みのApp Storeスクリーンショットと、ローカライズした文言を入力して、提出前に次の項目をローカルで検査するCLIです。

- 文字のoverflow（はみ出し）の疑い
- 危険な改行（禁則・分断）
- 禁止領域への侵入
- 寸法・形式・alphaの不一致
- 必要な画像の欠落

**できないこと**

- スクショの生成、デザイン編集、翻訳、App Storeへの提出は行いません。
- 入力画像は変更しません。出力するのはレポート（JSON/HTML）と、その中で使う画像のコピーだけです。
- 本ツールの結果は、App Store審査やアップロードの成功を保証しません。
- 画像の外へ切れて消えた文字や、元のテキストboxは、完成画像だけからは確定できません。情報が足りない項目は `UNKNOWN` として返し、`PASS` にはしません。

## クイックスタート

macOS 13以降で、Swift 5.9以降を使います（Linuxでも検査の中核部分は動作します。詳しくは後述）。

```sh
cd copyfit
swift build -c release
.build/release/copyfit audit --manifest Fixtures/demo12/manifest.json --copy Fixtures/demo12/copy.csv --out /tmp/copyfit-report
open /tmp/copyfit-report/index.html
# CI向け: 未確認のWARN/UNKNOWNが残っている場合も失敗扱いにする
.build/release/copyfit audit --manifest input/manifest.json --copy input/copy.csv --out report --strict
swift test
```

| 終了コード | 意味 |
|---|---|
| 0 | FAILなし。WARN/UNKNOWNの件数は表示されます。**提出が成功する保証ではありません** |
| 1 | 確定したFAILがあります |
| 2 | 入力エラーまたは実行エラー（path逸脱、上限超過、manifestの不正など） |
| 3 | `--strict` 指定時に、未確認のWARN/UNKNOWNが残っています |

主なオプション:

- `--no-ocr`: OCRを行いません
- `--ruleset <file>`: 確認済みのrulesetを明示的に指定します
- `--now YYYY-MM-DD`: 基準日を固定します（再現用）
- `--json`: 要約を標準出力にJSONで出します
- `--no-color`: 色付き表示を無効にします（環境変数 `NO_COLOR` でも可）
- `copyfit rulesets`: 同梱のruleset一覧を表示します

## 入力

`input/manifest.json` と `copy.csv`（`locale,key,text` の3列）を用意します。画像のpathはmanifestからの相対pathで指定します。ファイル名から内容を推測せず、manifestの記載を正とします。詳細は [docs/INPUT_SCHEMA.md](docs/INPUT_SCHEMA.md) を参照してください。

## プラットフォームによる違い

| 機能 | macOS | Linux |
|---|---|---|
| manifest/文言/欠落/重複/寸法/alpha/禁止領域/明示改行の禁則 | ✓ | ✓ |
| ImageIOによるデコード確認 | ✓ | — （PNGのchunk CRCとJPEGのmarkerによる構造検査のみ） |
| OCR照合（Vision）TEXT001/FIT002 | ✓ | — （UNKNOWN） |
| 文字fit計測（CoreText）FIT001 | ✓ | — （UNKNOWN） |

## ドキュメント

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)：構成とADR（Swift CLIを選んだ理由、Linuxでの開発）
- [docs/INPUT_SCHEMA.md](docs/INPUT_SCHEMA.md)：manifest、文言、座標の契約
- [docs/RULES.md](docs/RULES.md)：ルール一覧、判定の根拠、rulesetの更新手順
- [docs/TEST_PLAN.md](docs/TEST_PLAN.md)：fixture、受入基準、実行結果
- [docs/PRIVACY.md](docs/PRIVACY.md)：データの扱い
- [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md)：既知の制限
- [docs/SPIKE_RESULT.md](docs/SPIKE_RESULT.md)：Technical/Market Spikeの判定
- [docs/MARKET_EVIDENCE.md](docs/MARKET_EVIDENCE.md)：市場調査の記録
- [docs/INTERNAL_USE_RESULT.md](docs/INTERNAL_USE_RESULT.md)：内部利用の結果（実案件では未検証）

## 規約について

着手時に「UNRE Labs App Constitution」を探しましたが、このrepositoryにも、作業環境で検索できた範囲にも見つかりませんでした（2026-10-03、ファイル名と本文で検索）。そのため内容は推測で補っていません。見つかり次第、本ツールに適用されるか確認してください。
