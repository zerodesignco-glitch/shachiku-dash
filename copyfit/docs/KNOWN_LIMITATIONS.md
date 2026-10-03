# 既知の制限

## 原理的な限界

- **完成した画像だけでは、確定できないことがあります。**
  - 画像の外へ切れて消えた文字は、OCRでは見つかりません。
  - 元のテキストboxの位置は、画像からは分かりません。
  - OCRで読めないことを、文字の欠落とは判断しません（UNKNOWNとして扱います）。
  - 文字のはみ出しを確定（FAIL）できるのは、`layoutMetadataVerified: true` のmetadataをCoreTextで組んだ場合だけです。
- **CoreTextの計測は、デザインツールの組版と一致しません。** Figma、Sketch、Photoshopとは、字形、カーニング、行送り、禁則の処理系が異なります。境界ぎりぎりのケース（数px）では、結果が食い違うことがあります。
- **折返しは送り幅（advance）基準です。** CoreTextは字のink幅ではなく送り幅で改行するため、ink幅ちょうどのboxでも折り返すことがあります（macOS CIで確認）。FIT001は「CoreTextで組んだ行数・全glyph配置・ink範囲」で判定します。
- **fontの代替はしません。** 指定したPostScript名のfontが入っていなければ、FIT001はUNKNOWNになります。

## 実装上の制限（v0.1）

- **macOSのadapter（Vision、CoreText、ImageIO）は、初回の開発環境（Linux）ではコンパイルも実行もしていません。** GitHub Actionsの`macos-15` jobで確認する前提です。選定したMacでの実測（12画像の処理時間、Visionの精度、メモリ使用量）は**未実施**です。
- **Linuxでの扱い**：OCRとfit計測は常にUNKNOWNです。画像の破損は構造の検査（PNGのchunk CRCとIEND、JPEGのmarkerとEOI）だけで判定し、画素のデコードは行いません。
- **OCRのheuristic（TEXT001、FIT002）は精度が未評価です。** 実機のOCRデータセットで、precision、recall、UNKNOWN率を測る必要があります。測った結果が目標（precision 90%）に届かない場合は、既定でOFFにする判断が必要です。
- **改行のheuristic（BREAK002）**：ラベル付きの44サンプルでprecision 0.95でした。サンプルは自作で、規模も小さいので、実案件で再評価してください。
- **禁則**：日本語・英語・ドイツ語の初期セットだけを扱います。中国語・韓国語、縦書き、ルビ、分離禁止の網羅的な処理は未対応です。
- **RGB色空間**：Appleの公式ページの本文では要件を確認できなかったため、検査していません（フォーラムには「not in the RGB color space」というアップロードエラーの報告があります）。CMYKのJPEGは、color descriptionとしてレポートに表示するだけです。
- **端末とmockupの自動判別はしません。** targetはmanifestで宣言してください。端末mockupの中にあるcontent viewportや禁止領域も、明示的に入力する必要があります。
- **ruleset**：同梱しているのは2026-10-03の1件だけです。Appleの仕様が変わったら、手作業で更新します（[RULES.md](RULES.md)を参照）。
- **上限**（40MP、100MB/枚、300枚/run）は暫定値です。
- **HTMLレポート**：表示ではJavaScriptを使いません。画像の原寸表示は、ブラウザで画像を開くリンクで行います。
- **配置**：現状は公開ページ用のrepository（`shachiku-dash`）の `copyfit/` に置いています。このrepositoryのPages workflowはrepository全体を公開するため、mainにmergeすると、ソースと合成fixtureがGitHub Pagesに載ります（機密は含みません）。専用のrepositoryへ移すことを推奨します。
