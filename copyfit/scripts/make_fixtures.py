#!/usr/bin/env python3
"""合成fixtureを生成する（開発時のみ。Pillowが必要: pip install pillow）。

生成物はすべて合成データ。実製品のスクリーンショットや顧客データは含めない。
  python3 scripts/make_fixtures.py            # Fixtures/ を再生成
fontは生成環境のIPAGothic/DejaVu Sansを使う。manifestのfont指定はmacOS標準fontで、
画像の描画fontとは一致しないため layoutMetadataVerified は false にしている。
"""
import json
import os
import shutil
import struct
import sys
import zlib

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Fixtures")
JA_FONT = "/usr/share/fonts/opentype/ipafont-gothic/ipag.ttf"
LATIN_FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
RULESET = "apple-screenshots-2026-10-03"

IPHONE = ("iphone-6.9", (1290, 2796))
IPAD = ("ipad-13", (2064, 2752))

MAC_FONT = {"ja-JP": "HiraginoSans-W6", "en-US": "Helvetica-Bold", "de-DE": "Helvetica-Bold"}


def font_for(locale, size):
    return ImageFont.truetype(JA_FONT if locale.startswith("ja") else LATIN_FONT, size)


def headline_rect(size):
    w, _ = size
    return [80, 160, w - 160, 300]


def render(path, size, locale, text, rect, mode="RGB", overflow=False, mockup=True, faint=False):
    """背景・端末mockup風の枠・見出しを描く。overflow=Trueなら1行で描いてboxと画像端からはみ出させる。"""
    w, h = size
    img = Image.new(mode, size, (238, 242, 250, 255) if mode == "RGBA" else (238, 242, 250))
    d = ImageDraw.Draw(img)
    if mode == "RGBA":
        d.rectangle([0, 0, w, 120], fill=(0, 0, 0, 0))  # 上端を透明にする
    if mockup:
        m = int(w * 0.12)
        d.rounded_rectangle([m, 560, w - m, h + 200], radius=90, fill=(30, 33, 40))
        d.rounded_rectangle([m + 30, 590, w - m - 30, h + 200], radius=70, fill=(250, 250, 252))
        for i in range(6):
            y = 760 + i * 220
            d.rounded_rectangle([m + 90, y, w - m - 90, y + 160], radius=24, fill=(225, 231, 245))
    fs = 96
    font = font_for(locale, fs)
    color = (200, 205, 215) if faint else (20, 24, 32)
    x, y, rw, rh = rect
    lines = [text.replace("\n", " ")] if overflow else text.split("\n")
    lh = 120
    top = y + (rh - lh * len(lines)) / 2
    for i, line in enumerate(lines):
        tw = d.textlength(line, font=font)
        tx = x + 20 if overflow else x + (rw - tw) / 2
        d.text((tx, top + i * lh + (lh - fs) / 2), line, font=font, fill=color)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, format="PNG", optimize=True)  # 拡張子に関係なくPNG（ext-mismatch fixture用）


def region(locale, rect, copy_key="headline", max_lines=2):
    return {
        "id": "headline",
        "copyKey": copy_key,
        "rectPx": rect,
        "maxLines": max_lines,
        "fontPostScriptName": MAC_FONT[locale],
        "fontSizePx": 96,
        "lineHeightPx": 120,
        "trackingPx": 0,
        "alignment": "center",
        "layoutMetadataVerified": False,
    }


def write_json(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")


def write_csv(path, rows):
    def q(s):
        return '"' + s.replace('"', '""') + '"' if any(c in s for c in ',"\n') else s

    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write("locale,key,text\n")
        for r in rows:
            f.write(",".join(q(c) for c in r) + "\n")


# ---------------------------------------------------------------- demo12

DEMO_COPY = {
    ("ja-JP", "headline.01"): "毎日の通勤を、\nもっと速く。",
    ("en-US", "headline.01"): "Make every commute\nfaster.",
    ("de-DE", "headline.01"): "Jeden Arbeitsweg spürbar schneller und entspannter machen",
    ("ja-JP", "headline.02"): "残業時間を自動で記録し\n、グラフで振り返る",
    ("en-US", "headline.02"): "Track overtime\nautomatically",
    ("de-DE", "headline.02"): "Überstunden automatisch\nerfassen",
    ("ja-JP", "badge"): "NEW",
    ("en-US", "badge"): "NEW",
    ("de-DE", "badge"): "NEU",
}


def make_demo12():
    base = os.path.join(ROOT, "demo12")
    shutil.rmtree(base, ignore_errors=True)
    assets = []
    expected = []
    for locale in ["ja-JP", "en-US", "de-DE"]:
        for target, size in [IPHONE, IPAD]:
            for slot in ["01", "02"]:
                key = f"{locale}/{target}/{slot}"
                path = f"images/{locale}/{target}/{slot}.png"
                text = DEMO_COPY[(locale, f"headline.{slot}")]
                rect = headline_rect(size)
                img_size, mode, overflow, faint = size, "RGB", False, False
                if key == "de-DE/ipad-13/02":
                    expected.append({"ruleID": "ASSET001", "status": "FAIL", "asset": key})
                    continue  # 欠落asset
                if key == "en-US/iphone-6.9/02":
                    img_size = (1289, 2796)  # 1px違い
                    expected.append({"ruleID": "IMAGE001", "status": "FAIL", "asset": key})
                    expected.append({"ruleID": "IMAGE001", "status": "FAIL", "asset": key, "note": "apple"})
                if key == "ja-JP/ipad-13/01":
                    mode = "RGBA"  # 透明PNG
                    expected.append({"ruleID": "IMAGE002", "status": "FAIL", "asset": key})
                if key == "de-DE/iphone-6.9/01":
                    overflow = True  # 領域・画像端からはみ出す見出し
                if key == "en-US/ipad-13/02":
                    faint = True  # 低コントラスト（OCR不確実）
                render(os.path.join(base, path), img_size, locale, text, rect, mode=mode, overflow=overflow, faint=faint)
                regions = [region(locale, rect, f"headline.{slot}")]
                forbidden = []
                if slot == "01":
                    regions.append({"id": "badge", "copyKey": "badge", "rectPx": [80, 40, 300, 100]})
                    # 端末mockup上部（ダイナミックアイランド相当）を社内ルールの禁止領域とする例
                    m = int(size[0] * 0.12)
                    forbidden.append({"id": "mockup-top", "rectPx": [m, 560, size[0] - 2 * m, 60],
                                      "note": "端末mockup上端（社内design rule）"})
                assets.append({
                    "locale": locale, "target": target, "slot": slot, "path": path,
                    "expectedPixelSize": list(size), "textRegions": regions, "forbiddenRectsPx": forbidden,
                })
    manifest = {
        "schemaVersion": 1,
        "ruleset": RULESET,
        "requiredLocales": ["ja-JP", "en-US", "de-DE"],
        "requiredTargets": ["iphone-6.9", "ipad-13"],
        "requiredSlots": ["01", "02"],
        "fallbackPolicy": "explicit-only",
        "assets": assets,
        "noBreakPhrases": {"ja-JP": ["残業時間"], "en-US": ["Pro Max"], "de-DE": []},
    }
    write_json(os.path.join(base, "manifest.json"), manifest)
    rows = [[l, k, t] for (l, k), t in DEMO_COPY.items()]
    write_csv(os.path.join(base, "copy.csv"), rows)
    heuristic = [{"ruleID": "COPY002", "status": "WARN", "asset": None, "region": "badge"}]
    expected += [
        {"ruleID": "BREAK001", "status": "WARN", "asset": "ja-JP/iphone-6.9/02"},
        {"ruleID": "BREAK001", "status": "WARN", "asset": "ja-JP/ipad-13/02"},
    ]
    write_json(os.path.join(base, "expected.json"), {"description": "Technical spike用12画像セット（1件欠落）", "deterministic": expected,
                                                        "heuristicMustInclude": heuristic, "exitCode": 1})


# ---------------------------------------------------------------- edge cases


def case(name, assets_spec, copy_rows, expected, *, locales=("en-US",), targets=("iphone-6.9",), slots=("01",),
         ruleset=RULESET, exit_code=None, ocr=None, extra=None, now=None, ruleset_file=None, heuristic=None):
    base = os.path.join(ROOT, "cases", name)
    shutil.rmtree(base, ignore_errors=True)
    os.makedirs(base)
    assets = []
    for a in assets_spec:
        a = dict(a)
        gen = a.pop("_gen", None)
        if gen:
            gen(os.path.join(base, a["path"]))
        assets.append(a)
    manifest = {
        "schemaVersion": 1,
        "requiredLocales": list(locales),
        "requiredTargets": list(targets),
        "requiredSlots": list(slots),
        "fallbackPolicy": "explicit-only",
        "assets": assets,
    }
    if ruleset is not None:
        manifest["ruleset"] = ruleset
    if extra:
        manifest.update(extra)
    write_json(os.path.join(base, "manifest.json"), manifest)
    write_csv(os.path.join(base, "copy.csv"), copy_rows)
    exp = {"deterministic": expected, "exitCode": exit_code}
    if heuristic:
        exp["heuristicMustInclude"] = heuristic
    if now:
        exp["now"] = now
    if ruleset_file:
        write_json(os.path.join(base, "ruleset.json"), ruleset_file)
        exp["rulesetFile"] = "ruleset.json"
    if ocr is not None:
        write_json(os.path.join(base, "ocr.json"), ocr)
    write_json(os.path.join(base, "expected.json"), exp)


def png(locale="en-US", text="Hello", size=(1290, 2796), mode="RGB", **kw):
    return lambda p: render(p, size, locale, text, headline_rect(size), mode=mode, **kw)


def asset(locale="en-US", target="iphone-6.9", slot="01", path=None, size=(1290, 2796), gen=None, regions=None, forbidden=None):
    path = path or f"images/{locale}/{target}/{slot}.png"
    return {
        "locale": locale, "target": target, "slot": slot, "path": path,
        "expectedPixelSize": list(size),
        "textRegions": regions if regions is not None else [region(locale, headline_rect(size), "headline")],
        "forbiddenRectsPx": forbidden or [],
        "_gen": gen if gen is not None else png(locale, "Hello world", size),
    }


def corrupt_png(path):
    render(path, (1290, 2796), "en-US", "Hello world", headline_rect((1290, 2796)))
    with open(path, "rb") as f:
        data = f.read()
    with open(path, "wb") as f:
        f.write(data[: len(data) // 2])  # 途中で切れたファイル


def huge_png_header(path):
    """IHDRが8000×6000（48MP）を主張する最小PNG。画素デコード前に上限で拒否されることを確認する。"""
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    raw = zlib.compress(b"\x00" * 10)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 8000, 6000, 8, 2, 0, 0, 0)) + chunk(b"IDAT", raw) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def jpeg_rotated(path):
    """EXIF orientation 6（90度回転）のJPEG。保存は2796×1290、表示は1290×2796。"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img = Image.new("RGB", (1290, 2796), (238, 242, 250))
    ImageDraw.Draw(img).text((200, 200), "Rotated", font=font_for("en-US", 96), fill=(0, 0, 0))
    stored = img.transpose(Image.Transpose.ROTATE_90)  # 2796×1290で保存
    exif = Image.Exif()
    exif[0x0112] = 6
    stored.save(path, "JPEG", quality=70, exif=exif.tobytes())


def make_cases():
    shutil.rmtree(os.path.join(ROOT, "cases"), ignore_errors=True)
    hello = [["en-US", "headline", "Hello world"]]

    case("normal-pass", [asset()], hello, [], exit_code=0)
    case("normal-pass-ja-de",
         [asset("ja-JP", gen=png("ja-JP", "通勤を、もっと速く。")), asset("de-DE", gen=png("de-DE", "Schneller pendeln"))],
         [["ja-JP", "headline", "通勤を、\nもっと速く。"], ["de-DE", "headline", "Schneller\npendeln"]],
         [], locales=("ja-JP", "de-DE"), exit_code=0)
    case("missing-locale", [asset()], hello + [["ja-JP", "headline", "こんにちは"]],
         [{"ruleID": "ASSET001", "status": "FAIL", "asset": "ja-JP/iphone-6.9/01"}],
         locales=("en-US", "ja-JP"), exit_code=1)
    case("missing-slot", [asset()], hello,
         [{"ruleID": "ASSET001", "status": "FAIL", "asset": "en-US/iphone-6.9/02"}], slots=("01", "02"), exit_code=1)
    case("missing-file", [dict(asset(), _gen=lambda p: None)], hello,
         [{"ruleID": "ASSET001", "status": "FAIL", "asset": "en-US/iphone-6.9/01"}], exit_code=1)
    case("explicit-fallback", [asset()], hello,
         [], locales=("en-US", "en-GB"), exit_code=0,
         extra={"fallbacks": [{"locale": "en-GB", "target": "iphone-6.9", "slot": "01", "useLocale": "en-US", "reason": "英国向け文言は米国版と同一"}]})
    case("duplicate-asset", [asset(), asset(path="images/en-US/iphone-6.9/01-copy.png")], hello,
         [{"ruleID": "ASSET002", "status": "FAIL", "asset": "en-US/iphone-6.9/01"}], exit_code=1)
    case("swapped-orientation",
         [asset(size=(1290, 2796), gen=png(size=(2796, 1290)))], hello,
         [{"ruleID": "IMAGE001", "status": "FAIL", "asset": "en-US/iphone-6.9/01"}], exit_code=1)
    case("off-by-1px", [asset(gen=png(size=(1290, 2795)))], hello,
         [{"ruleID": "IMAGE001", "status": "FAIL", "asset": "en-US/iphone-6.9/01"},
          {"ruleID": "IMAGE001", "status": "FAIL", "asset": "en-US/iphone-6.9/01"}], exit_code=1)
    case("alpha-png", [asset(gen=png(mode="RGBA"))], hello,
         [{"ruleID": "IMAGE002", "status": "FAIL", "asset": "en-US/iphone-6.9/01"}], exit_code=1)
    case("corrupt-png", [asset(gen=corrupt_png)], hello,
         [{"ruleID": "IMAGE003", "status": "FAIL", "asset": "en-US/iphone-6.9/01"}], exit_code=1)
    case("huge-image", [asset(gen=huge_png_header)], hello, [], exit_code=2)
    case("jpeg-exif-rotated", [asset(path="images/en-US/iphone-6.9/01.jpg", gen=jpeg_rotated, regions=[])], hello,
         [], exit_code=0)
    case("ext-mismatch", [asset(path="images/en-US/iphone-6.9/01.jpg")], hello,
         [{"ruleID": "IMAGE001", "status": "WARN", "asset": "en-US/iphone-6.9/01"}], exit_code=0)
    case("unknown-target", [asset(target="vision-pro")], hello,
         [{"ruleID": "RULE001", "status": "UNKNOWN", "asset": "en-US/vision-pro/01"}], targets=("vision-pro",), exit_code=0)
    case("no-ruleset", [asset()], hello,
         [{"ruleID": "RULE001", "status": "UNKNOWN", "asset": None},
          {"ruleID": "IMAGE002", "status": "UNKNOWN", "asset": "en-US/iphone-6.9/01"}], ruleset=None, exit_code=0)
    old = json.load(open(os.path.join(os.path.dirname(__file__), "..", "Sources", "CopyfitCore", "Rulesets", RULESET + ".json"), encoding="utf-8"))
    old["rulesetID"] = "apple-screenshots-2025-01-01"
    old["checkedAt"] = "2025-01-01"
    case("expired-ruleset", [asset()], hello,
         [{"ruleID": "RULE001", "status": "WARN", "asset": None}], ruleset="apple-screenshots-2025-01-01",
         ruleset_file=old, now="2026-10-03", exit_code=0)
    case("copy-missing-key", [asset()], [["en-US", "other", "x"]],
         [{"ruleID": "COPY001", "status": "FAIL", "asset": "en-US/iphone-6.9/01", "region": "headline"}], exit_code=1)
    case("copy-empty", [asset()], [["en-US", "headline", ""]],
         [{"ruleID": "COPY001", "status": "FAIL", "asset": "en-US/iphone-6.9/01", "region": "headline"}], exit_code=1)
    case("copy-duplicate", [asset()], [["en-US", "headline", "A"], ["en-US", "headline", "B"]],
         [{"ruleID": "COPY001", "status": "FAIL", "asset": "en-US/*/*", "region": "headline"}], exit_code=1)
    case("mockup-forbidden",
         [asset(forbidden=[{"id": "device-notch", "rectPx": [500, 200, 300, 120], "note": "端末mockupのカメラ部"}])], hello,
         [{"ruleID": "SAFE001", "status": "WARN", "asset": "en-US/iphone-6.9/01", "region": "headline"}], exit_code=0)
    case("kinsoku-line-start", [asset("ja-JP", gen=png("ja-JP", "記録し\n、振り返る"))],
         [["ja-JP", "headline", "残業時間を記録し\n、グラフで振り返る"]],
         [{"ruleID": "BREAK001", "status": "WARN", "asset": "ja-JP/iphone-6.9/01", "region": "headline"}],
         locales=("ja-JP",), exit_code=0)
    case("missing-font-placeholder",
         [asset(regions=[dict(region("en-US", headline_rect((1290, 2796)), "headline"), fontPostScriptName="REPLACE_WITH_INSTALLED_FONT")])],
         hello, [], exit_code=0)
    case("malicious-strings", [asset()],
         [["en-US", "headline", "<script>alert('x')</script> & \"quotes\""]], [], exit_code=0)
    case("path-traversal", [dict(asset(), path="../outside.png", _gen=lambda p: None)], hello, [], exit_code=2)
    case("low-confidence-ocr", [asset(gen=png(faint=True))], hello, [], exit_code=0,
         ocr={"01.png": [{"text": "Hel1o wor1d", "boundingBox": [300, 250, 690, 100], "confidence": 0.31, "engineRevision": "fixture"}]},
         heuristic=[{"ruleID": "TEXT001", "status": "UNKNOWN", "asset": "en-US/iphone-6.9/01", "region": "headline"}])
    case("ocr-mismatch", [asset()], hello, [], exit_code=0,
         ocr={"01.png": [{"text": "Hello wor", "boundingBox": [300, 250, 690, 100], "confidence": 0.95, "engineRevision": "fixture"}]},
         heuristic=[{"ruleID": "TEXT001", "status": "WARN", "asset": "en-US/iphone-6.9/01", "region": "headline"}])
    case("ocr-edge-overflow", [asset("de-DE", gen=png("de-DE", "Jeden Arbeitsweg spürbar schneller machen", overflow=True))],
         [["de-DE", "headline", "Jeden Arbeitsweg spürbar schneller machen"]], [], locales=("de-DE",), exit_code=0,
         ocr={"01.png": [{"text": "Jeden Arbeitsweg spürbar schnell", "boundingBox": [100, 250, 1190, 100], "confidence": 0.9, "engineRevision": "fixture"}]},
         heuristic=[{"ruleID": "FIT002", "status": "WARN", "asset": "de-DE/iphone-6.9/01", "region": "headline"},
                    {"ruleID": "TEXT001", "status": "WARN", "asset": "de-DE/iphone-6.9/01", "region": "headline"}])


if __name__ == "__main__":
    if not os.path.exists(JA_FONT) or not os.path.exists(LATIN_FONT):
        sys.exit("必要なfontが見つかりません: " + JA_FONT + ", " + LATIN_FONT)
    make_demo12()
    make_cases()
    print("generated:", os.path.abspath(ROOT))
