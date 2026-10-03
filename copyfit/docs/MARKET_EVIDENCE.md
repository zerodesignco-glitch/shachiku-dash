# Market Evidence（確認日 2026-10-03）

机上調査のみです。誰にも連絡を取っていません。

調査環境のproxyにより、多くのvendorサイトが取得できませんでした（theapplaunchpad.com、screenshots.pro、previewed.app、app-mockup.com、screenhance.com、docs.fastlane.tools、reddit等）。そのため下表で「検索snippet」と書いた行は、**ページを直接見て確認したものではありません**。外販を判断する前に、直接確認し直してください。

## 代替手段

| 名前 / URL | 分類 | 価格 | 寸法検証 | 文字溢れ検出 | locale QA | 代わりに手作業でやること |
|---|---|---|---|---|---|---|
| App Store Connectのupload検証 https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications | 公式の最終関門 | 開発者プログラムに含まれる | uploadの時点で拒否される（事前のローカル検証はない） | なし | なし | 拒否されたら書き出し直してupload |
| fastlane deliver（AppScreenshotValidator）/ precheck / frameit https://github.com/fastlane/fastlane | OSS | 無料（MIT） | deliverがupload前に寸法と拡張子を検証する。ソース上、alphaと色空間の検査は見当たらない | なし（frameitは、収まらない文字を警告なしに縮小する） | なし | Appleが新しいサイズを追加したら、fastlaneの対応を待つ |
| asc CLI https://github.com/rorkai/App-Store-Connect-CLI | OSS | 無料 | `asc screenshots validate` でローカル検証できる。alphaはskill側で `sips -g hasAlpha` を使う | なし | 計画（matrix）を作る機能あり。欠落を検出するかは未確認 | 文字溢れは目視 |
| framaraのapp-store-screenshots-skill https://github.com/framara/app-store-screenshots-skill / Axiom https://github.com/CharlesWiltgen/Axiom | OSSのagent skill | 無料 | 書き出しサイズを固定 | **生成時に**見出しを自動で収める（auto-fit）。完成した画像の監査ではない | 39 locale | LLM agentが前提。決定論的なCLIではない（**最も近い競合**） |
| AppLaunchpad https://theapplaunchpad.com | 作成・翻訳 | 検索snippet：Pro $29/月 | 書き出し側で対応 | 監査はなし（AI翻訳と、layoutを保った複製） | 翻訳あり | 生成した後は目視 |
| Screenshots Pro https://screenshots.pro | 作成・翻訳 | 検索snippet：$19 / $49 /月 | 書き出し側で対応 | localeごとの並列preview（目視） | 翻訳あり | 目視 |
| 手作業・自作script（`sips`、Preview、ImageMagick） | 無料 | — | scriptを書けば可能 | 不可（目視） | フォルダを数える | フォーラムで回答されるのはほぼこの方法 |

## 開発者の痛みを示す公開証拠

**A. 寸法、alpha、色空間でuploadを拒否される**（一次投稿あり。繰り返し発生している）

1. https://developer.apple.com/forums/thread/809273（2025-12）：1240×2688で拒否された（正しくは1242×2688）。2pxのずれ。
2. https://developer.apple.com/forums/thread/763693（2024-09）：Simulatorで撮った画像が「wrong dimensions」で拒否された。
3. https://developer.apple.com/forums/thread/648944（2020〜2023、返信30件）：IMAGE_TOOL_FAILURE。回避策として「Export → Uncheck Alpha」が挙がっている。
4. https://developer.apple.com/forums/thread/649878 と https://developer.apple.com/forums/thread/699931：「not in the RGB color space」と言われる。
5. https://github.com/fastlane/fastlane/issues/21558（2023-10）：iPhone 15のサイズが未対応。
6. https://github.com/fastlane/fastlane/issues/21759（2023-12）：localizeしたスクショが1px違う。

**B. ローカライズした文言のoverflowや改行**：**vendorが書いた記事しか見つかりませんでした**。開発者本人による一次投稿は見つかっていません。日本語の禁則についての痛みを示す証拠は0件です。

**C. 単体の監査ツールを試したい・買いたいという意思**：**見つかりませんでした**。お金を払っている証拠があるのは、作成・翻訳ツール（月額$19〜49）だけです。

## 判定

- 「作成・翻訳の市場に課金需要がある」は**成立**します。「監査ツール単体にお金を払う意思がある」は**証拠なし**です。この2つは分けて考える必要があります。
- 外販GOの条件「外部の具体的な痛みが2件以上、かつ試す・買う意思が1件以上」については、痛みは寸法・alphaの系統で満たします。ただし文字溢れ・禁則の系統では満たしません。試す・買う意思は0件です。→ **外販HOLD**
- 寸法検証はすでに無料（fastlane、asc CLI、Apple自身）で手に入ります。差別化できる余地は、「完成した画像に対する文字溢れ・禁則・禁止領域の監査」「locale×target×slotの欠落一覧」「オフラインで決定論的に動くこと」に限られます。
- 価格の仮説（検証対象であり、確定値ではありません）：買い切りで¥800〜1,500。macOSのUIを作る費用は、これとは別に見積もります。
