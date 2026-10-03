# Spike Result（2026-10-03）

| 判断 | 結果 |
|---|---|
| **内部MVP** | **条件付きGO**。macOSのCIが通り、選定したMacで実測するまでは、OCRとfitの部分は「仮」とする |
| **外販** | **HOLD** |

## 計画（記録）

1. repositoryを確認する。規約（Constitution）を探したが見つからなかった。
2. Market Spikeを、subagentによる机上調査で並行して実施する。
3. Swift Packageで、core（OS非依存）、macOS adapter、CLIを作る。
4. 12画像のfixtureと28件のedge caseを用意する。
5. JSON/HTMLレポートを出す。
6. 文書をまとめる。

## Technical Spike

縦に一通り通した範囲は次のとおりです。

- manifestの読み込み
- 寸法、形式、alpha、破損の検査
- 文言との照合（明示改行による禁則）
- OCRの照合ロジック（固定観測を注入）
- JSON/HTMLレポートの出力
- 1コマンドでの実行と終了コード

| GO条件 | 状態 |
|---|---|
| ネットワークなしで再現できる | ✓（外部依存0、通信なし。同じ入力から同じ結果、golden testあり） |
| 欠落、寸法などの確定ルールを正しく検出する | ✓（fixtureで見逃し0、誤検知0） |
| OCRの不確かさを表示する | ✓（ロジックとレポート：confidence、UNKNOWN、原文とOCRの差分）。△ Visionの実機での精度は**未測定** |
| 1コマンドで現場の確認時間を減らせる | ✓ 寸法、欠落、alpha、禁則、禁止領域の一覧は即座に出る。△ 実案件での時間短縮は**未検証** |
| 12画像を準備5分以内・検査30秒程度（選定Mac） | △ 検査はLinuxで0.05〜0.18秒（OCRなし）。**Macでの実測は未実施**。manifestの準備時間も未測定（textRegionの座標とfont情報を手で書く必要があり、ここが最大のリスク） |

**UNREの既存workflowから、box情報やfont情報を取れるか**：UNREの素材と既存workflowが手元にないため、確認できていません。デザインツールから書き出せない場合、文字検査の価値はOCRによる推定（WARN/UNKNOWN）に限られます。

**HOLD・NO GOに切り替える基準**：manifestの準備が目視確認より重い、またはOCRの誤警告が多い場合は、範囲を「寸法、欠落、alpha、明示改行の禁則、手動reviewの補助」に絞ります。その場合、「Copyfitの完全な監査」とは呼びません。

## Market Spike

詳細は [MARKET_EVIDENCE.md](MARKET_EVIDENCE.md) を参照してください。

- 寸法、alpha、色空間による拒否という痛みは、繰り返し報告されています（Apple Forums、fastlaneのissue）。
- 文字溢れや禁則の痛みについては、一次証拠がありません。
- 単体の監査ツールを試したい・買いたいという意思は、0件でした。

したがって**外販はHOLD**です。内部で動くことだけを理由に、Storeへの出品や価格決定に進まないでください。

## 次の手順

1. PRのmacOS CIの結果を確認する（Visionの座標、CoreTextの境界）。
2. 選定したMacで、demo12の処理時間とメモリを実測する。
3. UNREの実案件1件分の素材で、目視時間の前後、不備の発見数、不要な警告の数を記録する。結果は [INTERNAL_USE_RESULT.md](INTERNAL_USE_RESULT.md) に書く。
4. 実機OCRでTEXT001とFIT002のprecisionを評価する。
