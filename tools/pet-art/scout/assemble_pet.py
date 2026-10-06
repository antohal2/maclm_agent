#!/usr/bin/env python3
"""
assemble_pet.py (v2) — собирает spritesheet.png + pet.json для maclm-agent
из полосок кадров, сгенерированных AI-генератором картинок.

Assembles spritesheet.png + pet.json for maclm-agent from AI-generated
frame strips (one image per state, frames in one horizontal row,
flat magenta #FF00FF background).

Что изменилось относительно v1 / Changes vs v1:
  * адаптивная палитра (по всему листу), а не фиксированная палитра Брони
    adaptive global palette instead of the fixed Bronya palette
  * общий масштаб и общая вертикальная опора на состояние: движение по
    вертикали (дыхание, подвес) сохраняется, ноги не «прыгают»
    one scale + one vertical anchor per state: vertical motion is preserved
  * надёжная нарезка кадров по столбцам, склейка/деление по числу кадров
    robust frame splitting by columns
  * --mul state=K — ручная подгонка размера состояния
    --mul state=K — per-state manual size tweak

Usage:
  pip install pillow numpy
  python3 assemble_pet.py --input ./raw --output ./scout --id scout --name "Скаут"
  python3 assemble_pet.py --input ./raw --output ./scout --mul sleep=1.15 --mul drag=1.2

Input files (fixed names):
  raw/idle.png raw/running.png raw/toolRunning.png raw/needsApproval.png
  raw/ready.png raw/failed.png raw/drag.png raw/sleep.png
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

FRAME = 64        # итоговый размер кадра / final frame size, px
CONTENT = 56      # макс. размер содержимого внутри кадра / max content size
BOTTOM_PAD = 4    # отступ от низа кадра (якорь «ноги») / bottom anchor padding
PALETTE_COLORS = 40
# Акцентные цвета, которые палитра не должна потерять (глаза, огни, искры)
# Accent colors the palette must never lose (eyes, LEDs, sparks)
ACCENTS = [(56, 200, 240), (255, 255, 255), (61, 220, 132), (255, 77, 77),
           (255, 176, 32), (255, 233, 168), (143, 227, 255), (30, 27, 46)]

# Порядок строк = контракт с кодом v0.4.x. Не менять без правки SPEC.
# Row order is a contract with the v0.4.x code. Do not change without SPEC update.
STATES = [
    ("idle", 6, 6, True),
    ("running", 8, 10, True),
    ("toolRunning", 8, 10, True),
    ("needsApproval", 6, 8, True),
    ("ready", 6, 8, True),
    ("failed", 6, 8, True),
    ("drag", 4, 8, True),
    ("sleep", 4, 3, True),
]


def chroma_key(img):
    """Magenta background, its dark shadow and pinkish fringe -> transparent."""
    arr = np.array(img.convert("RGBA")).astype(int)
    r, g, b, a = arr[..., 0], arr[..., 1], arr[..., 2], arr[..., 3]
    lo = np.minimum(r, b)
    bright = (r > 150) & (b > 110) & (g < lo - 60)
    shadow = (lo > 70) & (np.abs(r - b) < 80) & (lo - g > 45)   # тёмно-пурпурная тень
    bg = (a < 128) | bright | shadow
    arr[bg] = (0, 0, 0, 0)
    return Image.fromarray(arr.astype(np.uint8), "RGBA")


def find_segments(img, n):
    """Split a strip into n frames by empty columns."""
    alpha = np.array(img.getchannel("A")) > 0
    cols = alpha.sum(axis=0)
    segs, start = [], None
    for x, v in enumerate(list(cols) + [0]):
        if v > 2 and start is None:
            start = x
        elif v <= 2 and start is not None:
            if x - start > 12:          # отбрасываем мелкий мусор / drop specks
                segs.append([start, x])
            start = None
    # слишком много сегментов -> склеиваем соседей с наименьшим зазором
    while len(segs) > n:
        gaps = [segs[i + 1][0] - segs[i][1] for i in range(len(segs) - 1)]
        i = int(np.argmin(gaps))
        segs[i] = [segs[i][0], segs[i + 1][1]]
        del segs[i + 1]
    if len(segs) == n:
        return [tuple(s) for s in segs]
    print(f"  ! found {len(segs)} segments, expected {n} -> equal split", file=sys.stderr)
    cw = img.width / n
    return [(round(i * cw), round((i + 1) * cw)) for i in range(n)]


def main_body(alpha):
    """Largest blob (after dilation) = the robot itself, without dust/sparks/z."""
    solid = alpha > 0
    grown = ndimage.binary_dilation(solid, iterations=4)
    lab, k = ndimage.label(grown)
    if k == 0:
        return solid, None
    sizes = ndimage.sum(solid, lab, range(1, k + 1))
    main = lab == (1 + int(np.argmax(sizes)))
    body = solid & main
    ys, xs = np.where(body)
    return body, (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)


def analyze(img, n):
    """Per-state analysis: frame crops, robot bbox + area per frame."""
    segs = find_segments(img, n)
    frames = []
    for a, b in segs:
        c = img.crop((a, 0, b, img.height))
        alpha = np.array(c.getchannel("A"))
        body, bb = main_body(alpha)
        full = c.getbbox()
        frames.append({"img": c, "body_bb": bb, "full_bb": full,
                       "area": int(body.sum()) if bb else 0})
    return frames


def fit_scale(frames):
    """Largest scale at which the whole state (effects included) fits the cell."""
    valid = [f for f in frames if f["body_bb"]]
    anchor_y = max(f["body_bb"][3] for f in valid)
    left = right = top = 1
    for f in valid:
        ax = (f["body_bb"][0] + f["body_bb"][2]) / 2
        fb = f["full_bb"]
        bb = f["body_bb"]
        # по X ограничиваем только телом робота: пыль/искры могут слегка
        # обрезаться краем кадра / X-fit uses the robot body only, dust and sparks may clip
        left = max(left, ax - bb[0] + 4)
        right = max(right, bb[2] - ax + 4)
        top = max(top, anchor_y - fb[1])
    half = FRAME / 2 - 1
    return min(half / left, half / right, (FRAME - BOTTOM_PAD - 1) / top)


def render_state(frames, scale):
    valid = [f for f in frames if f["body_bb"]]
    anchor_y = max(f["body_bb"][3] for f in valid)
    out = []
    for f in frames:
        canvas = Image.new("RGBA", (FRAME * 3, FRAME * 3), (0, 0, 0, 0))
        if f["body_bb"]:
            c = f["img"]
            nw = max(1, round(c.width * scale))
            nh = max(1, round(c.height * scale))
            r = c.resize((nw, nh), Image.Resampling.BOX)
            r.putalpha(r.getchannel("A").point(lambda v: 255 if v >= 128 else 0))
            ax = (f["body_bb"][0] + f["body_bb"][2]) / 2 * scale
            ay = anchor_y * scale
            x = round(FRAME / 2 - ax)
            y = round(FRAME - BOTTOM_PAD - ay)
            canvas.alpha_composite(r, (FRAME + x, FRAME + y))
        out.append(canvas.crop((FRAME, FRAME, FRAME * 2, FRAME * 2)))
    return out


def quantize_sheet(sheet, colors):
    """Adaptive palette over the whole sheet + forced accent colors."""
    alpha = sheet.getchannel("A")
    rgb = Image.new("RGB", sheet.size, (30, 27, 46))
    rgb.paste(sheet, mask=alpha)
    base = rgb.quantize(colors=colors, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    flat = base.getpalette()[: colors * 3]
    pal = [tuple(flat[i:i + 3]) for i in range(0, len(flat), 3)]
    for c in ACCENTS:
        if c not in pal:
            pal.append(c)
    pal = pal[:256]
    data = [v for c in pal for v in c] + [0] * (768 - 3 * len(pal))
    pal_img = Image.new("P", (1, 1))
    pal_img.putpalette(data)
    q = rgb.quantize(palette=pal_img, dither=Image.Dither.NONE).convert("RGBA")
    q.putalpha(alpha)
    return q


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--id", default="scout")
    ap.add_argument("--name", default="Скаут")
    ap.add_argument("--colors", type=int, default=PALETTE_COLORS)
    ap.add_argument("--no-palette", action="store_true", help="skip palette quantization")
    ap.add_argument("--mul", action="append", default=[], metavar="STATE=K",
                    help="per-state size multiplier, e.g. sleep=1.15")
    ap.add_argument("--preview-scale", type=int, default=4)
    args = ap.parse_args()

    muls = {}
    for m in args.mul:
        k, v = m.split("=")
        muls[k] = float(v)

    cols = max(n for _, n, _, _ in STATES)
    sheet = Image.new("RGBA", (cols * FRAME, len(STATES) * FRAME), (0, 0, 0, 0))
    rows_meta = []

    analyzed = {}
    for state, n, fps, loop in STATES:
        src = args.input / f"{state}.png"
        if not src.exists():
            sys.exit(f"missing {src}")
        analyzed[state] = analyze(chroma_key(Image.open(src)), n)

    # опора по размеру: idle. Остальные состояния подгоняются так, чтобы
    # площадь робота совпадала с idle (одинаковый размер питомца везде)
    # size reference = idle; other states are matched by robot area
    idle = analyzed["idle"]
    ref_scale = fit_scale(idle)
    ref_area = np.mean([f["area"] for f in idle if f["body_bb"]])

    for row, (state, n, fps, loop) in enumerate(STATES):
        frames = analyzed[state]
        area = np.mean([f["area"] for f in frames if f["body_bb"]])
        want = ref_scale * (ref_area / area) ** 0.5 * muls.get(state, 1.0)
        scale = min(want, fit_scale(frames))
        flag = "" if scale >= want - 1e-9 else "  (clamped to fit)"
        print(f"[{row}] {state}: scale={scale:.4f} want={want:.4f}{flag}")
        for i, fr in enumerate(render_state(frames, scale)):
            sheet.alpha_composite(fr, (i * FRAME, row * FRAME))
        rows_meta.append({"row": row, "state": state, "frames": n, "fps": fps, "loop": loop})

    if not args.no_palette:
        sheet = quantize_sheet(sheet, args.colors)

    args.output.mkdir(parents=True, exist_ok=True)
    sheet.save(args.output / "spritesheet.png", optimize=True)

    manifest = {
        "version": 1,
        "id": args.id,
        "name": args.name,
        "frameSize": FRAME,
        "columns": cols,
        "rows": rows_meta,
        "reduceMotionFrame": 0,
    }
    (args.output / "pet.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")

    # превью в увеличении на шахматке / scaled preview on checkerboard
    s = args.preview_scale
    prev = Image.new("RGBA", (sheet.width * s, sheet.height * s))
    tile = 8 * s
    for y in range(0, prev.height, tile):
        for x in range(0, prev.width, tile):
            c = (60, 60, 70, 255) if (x // tile + y // tile) % 2 else (80, 80, 92, 255)
            prev.paste(c, (x, y, x + tile, y + tile))
    prev.alpha_composite(sheet.resize(prev.size, Image.Resampling.NEAREST))
    prev.save(args.output / "preview.png")
    print(f"done -> {args.output}/spritesheet.png ({sheet.width}x{sheet.height}), pet.json, preview.png")


if __name__ == "__main__":
    main()
