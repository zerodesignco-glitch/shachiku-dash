# ルール一覧（すべて ruleVersion 1）

根拠の種類はレポートに表示します。

- **apple-official**：Appleの公式要件（version付きrulesetから転記したもの）
- **project-rule**：プロジェクトの規則（manifestで宣言した内容）
- **heuristic**：推定（OCRや文字列の傾向による判定）
- **tool-meta**：ruleset自体の状態

| ID | 判定内容 | 状態 | 根拠 |
|---|---|---|---|
| ASSET001 | required locale×target×slot の画像が欠落している（manifestに記載がない、またはファイルがない） | FAIL。明示fallbackがあれば、採用元と理由を添えてPASS | project-rule |
| ASSET002 | 同じkeyの画像が複数ある | FAIL。どちらかを自動で選ばず、両方とも検査しない | project-rule |
| ASSET003 | requiredSlotsの数がAppleの上限（10枚）を超える | FAIL | apple-official |
| IMAGE001 | 寸法がmanifestの指定と違う／縦横が逆／rulesetの許容寸法にない／形式が非対応 | FAIL（実際の画素数で判定） | project-rule / apple-official |
| IMAGE001 | 拡張子と実際の形式が一致しない | WARN | project-rule |
| IMAGE002 | alpha channelや透過情報（PNGのcolor type 4/6、またはtRNS）がある | FAIL。rulesetがなければUNKNOWN | apple-official |
| IMAGE003 | 画像が破損している（chunkのCRC、IENDやEOIの欠落、ImageIOでデコードできない） | FAIL。その画像の他の検査は行わない | apple-official |
| COPY001 | 文言keyの欠落、空文字、同じlocale内での重複 | FAIL | project-rule |
| COPY002 | 同じ文言が複数のlocaleで使われている（翻訳漏れの疑い） | WARN。`copyAllowlist` に理由付きで登録すれば除外 | heuristic |
| FIT001 | CoreTextで組んだ結果が、全glyph配置・maxLines・box内のink範囲を満たさない | metadataが検証済みならFAIL、未検証ならWARN。収まっていてもmetadata未検証ならUNKNOWN。font・計測器・情報のいずれかが欠ける場合もUNKNOWN | project-rule |
| FIT002 | OCRで検出した文字領域が、boxの外（許容4px超）、禁止領域、画像の端に触れている | WARN（OCRの誤差があるため自動でFAILにしない） | heuristic |
| TEXT001 | OCR結果が期待する文言と一致しない | WARN。OCRが使えない、言語が非対応、文字を読めない、confidenceが低い場合はUNKNOWN | heuristic |
| BREAK001 | 行頭禁則・行末禁則、指定した禁止語の分断 | WARN。改行情報がない場合はUNKNOWN | project-rule |
| BREAK002 | 短い孤立行、数字と単位の分断 | WARN | heuristic |
| SAFE001 | 指定したbox、または計測したink範囲が禁止領域に入っている | metadataが検証済みならFAIL、未検証ならWARN | project-rule |
| RULE001 | rulesetの未指定・不明、未知のtarget | UNKNOWN（`--strict` では失敗扱い） | tool-meta |
| RULE001 | rulesetの確認日から90日を超えている、またはIDが一致しない | WARN | tool-meta |

## 改行の判定に使う行の取り方

次の優先順で、最初に得られたものを使います。どれを使ったかはevidenceに記録します。

1. CoreTextで組んだ行
2. 文言に明示された改行
3. OCRで読み取った行（推定）

どれも得られない場合は、BREAK001をUNKNOWNにします。

禁則の対象は、ja・en・deの初期セット（JIS X 4051の主要部分と、欧文の句読点）です。Unicode全体を網羅した実装ではありません。`breakAllowlist` には、理由、対象（locale、target、slot、region、rule）、期限が必須です。期限を過ぎるとWARNに戻ります。警告をまとめて無効にする手段はありません。

## OCRとの照合

- 比較の前に、NFCで正規化し、空白をまとめます（CJKのlocaleでは空白を除きます）。
- 句読点、数字、濁点、絵文字、ZWJは削りません。削って一致扱いにすることはしません。
- 期待する文言、OCRの文字列、差分の位置をレポートに並べて表示します。
- OCRで読めなかったことを「文字が欠落している」とは判断しません（UNKNOWNにします）。

## Apple rulesetの更新手順

1. 次の公式ページを開き、形式、alpha、許容寸法、表示区分、枚数を確認します。
   - https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications
   - https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots
2. `Sources/CopyfitCore/Rulesets/apple-screenshots-YYYY-MM-DD.json` を新しく作ります。端末名から寸法を計算せず、公式の表をそのまま転記してください。
3. fixtureとexpectedを更新し、`swift test` を通したうえで、レビューを経てcommitします。仕様の更新、確認日、fixtureの変更は同じcommitに含めてください。
4. 監査の実行中にAppleのページを自動で取得することはしません。確認日から90日を超えたrulesetはWARNになります。

### 同梱ruleset `apple-screenshots-2026-10-03`

公式ページは2026-10-03に確認しました。WebFetchでの抽出なので、実装時と外販時に原文と照合し直してください。

- 形式：`.jpeg` / `.jpg` / `.png`
- 「Images can't include alpha channels or transparencies.」
- 1セットあたり1〜10枚
- iPhoneは6.9" / 6.5" / 6.3" / 6.1" / 5.5"、iPadは13" / 12.9" / 11"の、縦横両方の寸法（JSONを参照）

RGB色空間の要件は、公式ページの本文では確認できませんでした（エラーメッセージとしてフォーラムで報告されています）。そのためrulesetには含めていません（KNOWN_LIMITATIONSを参照）。

「6.9"がない場合は6.5"の画像を縮小して使う」といった、表示区分間の自動scaleはAppleの仕様です。一方、「各localeの画像を個別に揃える」のはプロジェクトの方針です。copyfitが確認するのは、manifestに書いた必須の組み合わせだけです。
