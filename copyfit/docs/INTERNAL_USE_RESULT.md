# 内部利用結果

**状態：実案件では未検証です。**（2026-10-03時点）

UNREの実際の素材が提供されていないため、合成デモ（`Fixtures/demo12`）までを完成としています。内部での実績は記載していません（捏造しないため）。

## 合成デモでの結果（Linux、OCRとCoreTextなし）

コマンド：

```
copyfit audit --manifest Fixtures/demo12/manifest.json --copy Fixtures/demo12/copy.csv --out report
```

| 項目 | 結果 |
|---|---|
| 終了コード | 1 |
| 件数 | FAIL 4 / WARN 3 / UNKNOWN 42 / PASS 58 |
| 意図的に入れた確定不備 | 4件すべて検出：欠落1、1px違い（manifestの指定とAppleの許容寸法で計2件）、alpha 1 |
| WARN | 禁則2件、同一文言1件（すべて意図どおり） |
| 誤検知 | 0 |
| UNKNOWN | 主な理由は、OCRとfit計測がLinuxで使えないこと、およびmetadataが未検証であること |
| 処理時間 | 0.05秒（release） |

## 実案件で記録する項目（テンプレート）

| 項目 | 監査なし（目視のみ） | copyfitあり |
|---|---|---|
| 対象（locale × target × slot） | | |
| manifestの準備時間 | — | |
| 確認時間 | | |
| 見つかった不備の数（種類別） | | |
| 不要な警告の数 | — | |
| 見逃し（後から判明したもの） | | |
| 使用したMac / macOS / copyfitのversion | | |
