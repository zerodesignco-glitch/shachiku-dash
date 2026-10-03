# 入力契約（schemaVersion 1）

```text
input/
  manifest.json
  copy.csv            # または copy.json
  images/ja-JP/iphone-6.9/01.png
```

## manifest.json

```jsonc
{
  "schemaVersion": 1,
  "ruleset": "apple-screenshots-2026-10-03",   // 同梱ruleset ID（copyfit rulesets で確認）
  "requiredLocales": ["ja-JP", "en-US"],
  "requiredTargets": ["iphone-6.9"],            // ruleset の target ID
  "requiredSlots": ["01", "02"],
  "fallbackPolicy": "explicit-only",           // または "none"
  "fallbacks": [                                // 任意。採用元と理由をreportに表示
    {"locale": "en-GB", "target": "iphone-6.9", "slot": "01", "useLocale": "en-US", "reason": "文言同一"}
  ],
  "assets": [{
    "locale": "ja-JP", "target": "iphone-6.9", "slot": "01",
    "path": "images/ja-JP/iphone-6.9/01.png",  // manifestからの相対path。.. / 絶対path / root外symlinkは拒否
    "expectedPixelSize": [1290, 2796],         // 任意。プロジェクトが選んだ寸法
    "textRegions": [{
      "id": "headline",
      "copyKey": "headline.01",
      "rectPx": [80, 120, 1130, 300],          // x, y, width, height（向き正規化後・左上原点pixel）
      "maxLines": 2,
      "fontPostScriptName": "HiraginoSans-W6", // インストール済みfontのPostScript名
      "fontSizePx": 80, "lineHeightPx": 96, "trackingPx": 0,
      "alignment": "center",                   // left / center / right / justified
      "layoutMetadataVerified": false          // デザイン元と照合済みの場合だけtrue
    }],
    "forbiddenRectsPx": [                      // [x,y,w,h] 配列、または {id, rectPx, note}
      {"id": "mockup-notch", "rectPx": [520, 600, 250, 80], "note": "端末mockupのカメラ部（社内ルール）"}
    ]
  }],
  "copyAllowlist": [{"key": "brand.name", "reason": "ブランド名は全locale共通"}],
  "breakAllowlist": [{"locale": "ja-JP", "target": "iphone-6.9", "slot": "01", "regionID": "headline",
                      "ruleID": "BREAK001", "reason": "デザイン意図", "expires": "2026-12-31"}],
  "noBreakPhrases": {"ja-JP": ["残業時間"], "en-US": ["Pro Max"]},
  "ocr": {"enabled": true, "minConfidence": 0.5, "assignTolerancePx": 24, "edgeTolerancePx": 2},
  "heuristics": {"orphanLines": true, "orphanMaxGraphemesCJK": 2}
}
```

- 例に書いた `iphone-6.9`、rulesetのID、font名は、実際の環境に合わせて置き換えてください。1290×2796はiPhone 6.9"で許容される寸法の1つにすぎず、すべての端末に使えるわけではありません。
- `fontPostScriptName` が空の場合や `REPLACE_` で始まる場合は、layout情報がないものとして扱い、FIT001はUNKNOWNになります。
- 次の値を含むmanifestは、入力エラー（終了コード2）として拒否します。
  - `rectPx` の負値、幅0、要素数が4以外
  - 同じasset内での `textRegions.id` の重複
  - 理由の書かれていない `breakAllowlist`
  - 未対応の `schemaVersion`
- `rectPx` が画像の範囲外にある領域は検査しません。その領域の結果はUNKNOWNとして報告します（画像の寸法誤りによるFAILを入力エラーで隠さないためです）。
- 禁止領域は社内のdesign ruleや端末mockupの都合で設定するものであり、Appleの提出要件ではありません。画像全体に一律のiOS safe areaは適用しません。

## copy.csv

- UTF-8（BOMがあっても可）で、ヘッダは `locale,key,text` の3列に限ります。
- RFC 4180に準拠します。カンマ、改行、`"` を含む値は `"` で囲み、値の中の `"` は `""` と書きます。
- 引用符内の改行は、実際の改行として保持します（CRLFはLFに揃えます）。文字列としての `\n` は改行に変換しません。
- 空の文言、keyの欠落、同じlocaleでのkeyの重複は、ロード時には捨てず、COPY001でFAILにします。

## copy.json（CSVと同じ意味）

```json
{"schemaVersion": 1, "entries": [{"locale": "ja-JP", "key": "headline.01", "text": "毎日の通勤を、\nもっと速く。"}]}
```

## 上限（暫定）

| 項目 | 上限 | 超えた場合 |
|---|---|---|
| 画素数 | 40MP/枚（ヘッダの寸法で判定し、デコード前に拒否） | 終了コード2 |
| ファイルサイズ | 100MB/枚 | 終了コード2 |
| 1回あたりのasset数 | 300件 | 終了コード2 |
| manifest・文言ファイル | 10MB | 終了コード2 |
