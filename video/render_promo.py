#!/usr/bin/env python3
"""CamSync promo animation — 1080x1920@30fps, rendered frame-by-frame with Pillow.

Storyboard (37s):
  S0 hook        0.0–4.3   ink bg, SD card pops photos, “拍了很多好照片,然后呢?”
  S1 brand       4.3–8.1   paper bg, app icon + CamSync + tagline
  S2 connect     8.1–14.6  step 01 连接你的灵感 (devices -> iPhone)
  S3 select     14.6–21.1  step 02 挑选值得留下的 (grid + chips)
  S4 save       21.1–27.6  step 03 去你想去的地方 (3 destinations + counter)
  S5 trust      27.6–31.9  ink bg, 确实存好才算完成 + progress + privacy pills
  S6 outro      31.9–37.0  paper bg, icon + App Store 搜索引导 (no QR)

Usage:
  python3 render_promo.py                # full movie -> camsync-promo-9x16.mp4
  python3 render_promo.py --stills t1,t2 # render single frames to still_*.png
"""

import math
import os
import subprocess
import sys
from functools import lru_cache

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1080, 1920
FPS = 30
DUR = 37.0
SS = 2  # supersample factor for anti-aliasing

PAPER = (244, 243, 239)
INK = (32, 35, 31)
ORANGE = (250, 87, 40)
MUTED = (114, 117, 109)
LINE = (216, 217, 210)
WHITE = (255, 255, 255)
IOS_BLUE = (52, 120, 246)

ROOT = os.path.dirname(os.path.abspath(__file__))
ICON_PATH = os.path.join(ROOT, "..", "website", "public", "assets", "app-icon.png")

# ---------------------------------------------------------------- easing


def clamp(v, a=0.0, b=1.0):
    return max(a, min(b, v))


def lerp(a, b, t):
    return a + (b - a) * t


def remap(t, a, b):
    return clamp((t - a) / (b - a)) if b > a else 0.0


def ease_out_cubic(t):
    t = clamp(t)
    return 1 - (1 - t) ** 3


def ease_in_out_quint(t):
    t = clamp(t)
    return 4 * t**3 if t < 0.5 else 1 - (-(2 * t - 2) ** 3) / 2


def ease_out_back(t, s=1.55):
    t = clamp(t)
    if t <= 0:
        return 0.0
    if t >= 1:
        return 1.0
    t -= 1
    return 1 + t * t * ((s + 1) * t + s)


def ease_out_expo(t):
    t = clamp(t)
    return 1 if t >= 1 else 1 - 2 ** (-10 * t)


def ca(v):
    """clamp alpha byte 0-255"""
    return max(0, min(255, int(v)))


def mixc(c1, c2, t):
    return tuple(int(lerp(a, b, t)) for a, b in zip(c1, c2))


def fade_alpha(u, fin=0.18, fout=0.18):
    a = 1.0
    if u < fin:
        a = u / fin
    elif u > 1 - fout:
        a = (1 - u) / fout
    return clamp(a)


# ---------------------------------------------------------------- fonts


@lru_cache(maxsize=128)
def font(kind, size):
    size = max(6, int(round(size * SS)))
    paths = {
        "zh": ("/System/Library/Fonts/Hiragino Sans GB.ttc", 0),  # W3
        "zhb": ("/System/Library/Fonts/Hiragino Sans GB.ttc", 2),  # W6
        "lat": ("/System/Library/Fonts/HelveticaNeue.ttc", 10),  # Medium
        "latb": ("/System/Library/Fonts/HelveticaNeue.ttc", 1),  # Bold
        "latl": ("/System/Library/Fonts/HelveticaNeue.ttc", 7),  # Light
        "cond": ("/System/Library/Fonts/HelveticaNeue.ttc", 9),  # Condensed Black
    }
    p, i = paths[kind]
    return ImageFont.truetype(p, size, index=i)


def S(v):
    return v * SS


def pt(x, y):
    return (x * SS, y * SS)


def box(x, y, w, h):
    return [x * SS, y * SS, (x + w) * SS, (y + h) * SS]


def text_w(d, txt, f, tracking=0.0):
    if tracking <= 0:
        return d.textlength(txt, font=f) / SS
    total = sum(d.textlength(ch, font=f) for ch in txt) / SS
    return total + tracking * max(0, len(txt) - 1)


def draw_text(d, pos, txt, kind, size, fill, anchor="la", tracking=0.0):
    """anchor uses PIL anchors; pos in design px."""
    f = font(kind, size)
    if isinstance(fill, (tuple, list)) and len(fill) >= 4:
        fill = tuple(int(c) for c in fill[:3]) + (int(fill[3]),)
    if tracking > 0:
        total = text_w(d, txt, f, tracking)
        x = pos[0]
        if anchor[0] == "m":
            x -= total / 2
        elif anchor[0] == "r":
            x -= total
        y = pos[1]
        if anchor[1] == "m":
            y -= f.size / SS / 2 * 0.72
        elif anchor[1] == "d":
            y -= f.size / SS
        for ch in txt:
            d.text(pt(x, y), ch, font=f, fill=fill)
            x += d.textlength(ch, font=f) / SS + tracking
        return
    d.text(pt(*pos), txt, font=f, fill=fill, anchor=anchor)


def tracked_caps(d, pos, txt, size, fill, tracking=6.0, anchor="m"):
    amap = {"l": "lm", "r": "rm", "m": "mm"}
    draw_text(d, pos, txt, "lat", size, fill, anchor=amap.get(anchor, anchor), tracking=tracking)


# ---------------------------------------------------------------- primitives


def rect_box(d, x, y, w, h, r=0, **kw):
    if r > 0:
        d.rounded_rectangle(box(x, y, w, h), radius=r * SS, **kw)
    else:
        d.rectangle(box(x, y, w, h), **kw)


def shadow(d, x, y, w, h, r=24, off=10, color=(32, 35, 31, 26)):
    d.rounded_rectangle(box(x + off, y + off, w, h), radius=r * SS, fill=color)


def circle(d, cx, cy, r, **kw):
    d.ellipse([cx * SS - r * SS, cy * SS - r * SS, cx * SS + r * SS, cy * SS + r * SS], **kw)


def arrow_ne(d, cx, cy, size, color, width, alpha=255):
    """draw ↗ arrow centered at cx,cy"""
    c = color[:3] + (alpha,)
    s = size
    d.line([pt(cx - s * 0.5, cy + s * 0.5), pt(cx + s * 0.5, cy - s * 0.5)], fill=c, width=int(width * SS))
    d.line([pt(cx - s * 0.1, cy - s * 0.5), pt(cx + s * 0.5, cy - s * 0.5)], fill=c, width=int(width * SS))
    d.line([pt(cx + s * 0.5, cy - s * 0.1), pt(cx + s * 0.5, cy + s * 0.1)], fill=c, width=int(width * SS))


def arrow_e(d, x1, y1, x2, y2, color, width, head=14):
    c = color[:3] + (color[3] if len(color) > 3 else 255,)
    d.line([pt(x1, y1), pt(x2, y2)], fill=c, width=int(width * SS))
    ang = math.atan2(y2 - y1, x2 - x1)
    for da in (math.radians(150), math.radians(-150)):
        d.line([pt(x2, y2), pt(x2 + head * math.cos(ang + da), y2 + head * math.sin(ang + da))], fill=c, width=int(width * SS))


def check_mark(d, cx, cy, size, color, width, prog=1.0):
    """check with progressive draw (prog 0..1)"""
    if prog <= 0:
        return
    p1 = (-0.45, 0.05)
    p2 = (-0.1, 0.4)
    p3 = (0.5, -0.4)
    pts = [p1, p2, p3]
    total_len = (math.dist(p1, p2) + math.dist(p2, p3)) * size
    draw_len = total_len * prog
    seg1 = math.dist(p1, p2) * size
    c = color[:3] + (color[3] if len(color) > 3 else 255,)
    if draw_len <= seg1:
        t = draw_len / seg1
        d.line([pt(cx + p1[0] * size, cy + p1[1] * size), pt(cx + lerp(p1[0], p2[0], t) * size, cy + lerp(p1[1], p2[1], t) * size)], fill=c, width=int(width * SS))
    else:
        d.line([pt(cx + p1[0] * size, cy + p1[1] * size), pt(cx + p2[0] * size, cy + p2[1] * size)], fill=c, width=int(width * SS))
        t = (draw_len - seg1) / (math.dist(p2, p3) * size)
        d.line([pt(cx + p2[0] * size, cy + p2[1] * size), pt(cx + lerp(p2[0], p3[0], t) * size, cy + lerp(p2[1], p3[1], t) * size)], fill=c, width=int(width * SS))


def qbez(p0, p1, p2, t):
    x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t**2 * p2[0]
    y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t**2 * p2[1]
    return x, y


def dashed_path(d, pts, color, width, dash=10, gap=12, alpha=255):
    c = color[:3] + (alpha,)
    segs = []
    dist_acc = 0.0
    acc = []
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        seglen = math.dist(a, b)
        segs.append((a, b, seglen))
    for a, b, seglen in segs:
        steps = max(2, int(seglen))
        for i in range(steps):
            tt = i / (steps - 1)
            acc.append((lerp(a[0], b[0], tt), lerp(a[1], b[1], tt), dist_acc + seglen * tt))
        dist_acc += seglen
    drawing = True
    nextswitch = dash
    i = 0
    while i < len(acc) - 1:
        dd = acc[i][2]
        if dd >= nextswitch:
            drawing = not drawing
            nextswitch += dash if drawing else gap
        if drawing:
            d.line([pt(acc[i][0], acc[i][1]), pt(acc[i + 1][0], acc[i + 1][1])], fill=c, width=int(width * SS))
        i += 1


# ---------------------------------------------------------------- sprites

PHOTO_PALETTES = [
    ((250, 87, 40), (245, 162, 93)),
    ((62, 107, 142), (158, 195, 217)),
    ((95, 125, 90), (191, 211, 168)),
    ((110, 91, 142), (201, 184, 224)),
    ((217, 164, 65), (242, 216, 167)),
    ((65, 85, 107), (143, 166, 188)),
]


def gradient_img(w, h, c1, c2):
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / max(1, h - 1)
        c = mixc(c1, c2, t)
        for x in range(w):
            px[x, y] = c
    return img


@lru_cache(maxsize=16)
def photo_sprite(size_px, pal_i, glyph_i):
    """stylized polaroid: white frame + gradient photo + glyph. size = full width, SS-space"""
    size = int(size_px)
    frame = max(3, size // 26)
    bottom = int(frame * 2.4)
    spr = Image.new("RGBA", (size, size + bottom), (0, 0, 0, 0))
    d = ImageDraw.Draw(spr)
    d.rounded_rectangle([0, 0, size, size + bottom], radius=size * 0.09, fill=WHITE + (255,))
    ph = [frame, frame, size - frame, size - frame]
    d.rounded_rectangle(ph, radius=size * 0.055, fill=(230, 229, 224, 255))
    c1, c2 = PHOTO_PALETTES[pal_i % len(PHOTO_PALETTES)]
    grad = gradient_img(size - 2 * frame, size - 2 * frame, c1, c2)
    mask = Image.new("L", grad.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, grad.size[0] - 1, grad.size[1] - 1], radius=int(size * 0.05), fill=255)
    spr.paste(grad, (frame, frame), mask)
    gd = ImageDraw.Draw(spr)
    wc = (255, 255, 255, 215)
    if glyph_i == 0:  # sun + hills
        gd.ellipse([size * 0.58, size * 0.2, size * 0.78, size * 0.4], fill=wc)
        gd.polygon([(frame, size * 0.86), (size * 0.42, size * 0.48), (size * 0.66, size * 0.86)], fill=wc)
        gd.polygon([(size * 0.52, size * 0.86), (size * 0.78, size * 0.58), (size - frame, size * 0.86)], fill=(255, 255, 255, 170))
    elif glyph_i == 1:  # horizon + sun
        gd.ellipse([size * 0.3, size * 0.26, size * 0.5, size * 0.46], fill=wc)
        gd.line([frame + 2, size * 0.62, size - frame - 2, size * 0.62], fill=wc, width=max(2, size // 40))
        gd.line([frame + 2, size * 0.74, size - frame - 2, size * 0.74], fill=(255, 255, 255, 130), width=max(2, size // 48))
    elif glyph_i == 2:  # big sun arc
        gd.arc([size * 0.2, size * 0.25, size * 0.8, size * 0.85], 180, 360, fill=wc, width=max(3, size // 22))
        gd.line([frame + 2, size * 0.55, size - frame - 2, size * 0.55], fill=wc, width=max(2, size // 40))
    return spr


def paste_sprite(base, spr, cx, cy, scale=1.0, rot=0.0, alpha=255):
    if scale <= 0.01 or alpha <= 2:
        return
    w = max(2, int(spr.width * scale))
    h = max(2, int(spr.height * scale))
    img = spr.resize((w, h), Image.LANCZOS)
    if rot:
        img = img.rotate(rot, expand=True, resample=Image.BICUBIC)
    if alpha < 255:
        a = img.getchannel("A").point(lambda v: v * alpha // 255)
        img.putalpha(a)
    base.alpha_composite(img, (int(cx * SS - w / 2), int(cy * SS - h / 2)))


@lru_cache(maxsize=4)
def icon_sprite(size_px, radius_pct=0.225):
    try:
        icon = Image.open(ICON_PATH).convert("RGBA")
    except Exception:
        icon = Image.new("RGBA", (1024, 1024), ORANGE + (255,))
    icon = icon.resize((int(size_px), int(size_px)), Image.LANCZOS)
    mask = Image.new("L", icon.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, icon.size[0] - 1, icon.size[1] - 1], radius=int(size_px * radius_pct), fill=255)
    icon.putalpha(mask)
    # soft shadow
    sh = Image.new("RGBA", (icon.size[0] + 80, icon.size[1] + 80), (0, 0, 0, 0))
    a = icon.getchannel("A").point(lambda v: v * 60 // 255)
    sh.paste((32, 35, 31, 60), (50, 58), a)
    sh = sh.filter(ImageFilter.GaussianBlur(14 * SS // 2))
    sh.alpha_composite(icon, (40, 40))
    return sh


def paste_icon(base, cx, cy, size, scale=1.0, alpha=255):
    spr = icon_sprite(int(size * SS))
    paste_sprite(base, spr, cx, cy, scale, 0, alpha)


# --- device / destination icons (drawn directly, ink strokes) -------------


def draw_camera(d, cx, cy, w, color, alpha=255, lw=7):
    c = color[:3] + (alpha,)
    h = w * 0.72
    x, y = cx - w / 2, cy - h / 2
    d.rounded_rectangle([x * SS, y * SS, (x + w) * SS, (y + h) * SS], radius=w * 0.16 * SS, outline=c, width=int(lw * SS))
    d.rounded_rectangle([(cx - w * 0.16) * SS, (y - w * 0.14) * SS, (cx + w * 0.16) * SS, y * SS], radius=w * 0.05 * SS, fill=c)
    d.ellipse([(cx - w * 0.21) * SS, (cy - w * 0.21) * SS, (cx + w * 0.21) * SS, (cy + w * 0.21) * SS], outline=c, width=int(lw * SS))
    d.ellipse([(cx - w * 0.07) * SS, (cy - w * 0.07) * SS, (cx + w * 0.07) * SS, (cy + w * 0.07) * SS], outline=c, width=int(lw * 0.8 * SS))
    d.ellipse([(x + w * 0.74) * SS, (y + h * 0.14) * SS, (x + w * 0.86) * SS, (y + h * 0.14 + w * 0.09) * SS], fill=c)


def draw_sd(d, cx, cy, w, color, alpha=255, lw=7):
    c = color[:3] + (alpha,)
    h = w * 1.32
    x, y = cx - w / 2, cy - h / 2
    pts = [
        (x, y + w * 0.2),
        (x + w * 0.2, y),
        (x + w, y),
        (x + w, y + h),
        (x, y + h),
    ]
    d.polygon([(px * SS, py * SS) for px, py in pts], outline=c, width=int(lw * SS))
    for i in range(4):
        gx = x + w * (0.24 + i * 0.14)
        d.line([pt(gx, y + w * 0.045), pt(gx, y + w * 0.16)], fill=c, width=int(lw * 0.8 * SS))
    draw_text(d, (cx, cy + h * 0.22), "SD", "latb", w * 0.2, c, anchor="mm")


def draw_usb(d, cx, cy, w, color, alpha=255, lw=7):
    c = color[:3] + (alpha,)
    h = w * 0.62
    x, y = cx - w / 2, cy - h / 2
    d.rounded_rectangle([x * SS, (y + h * 0.3) * SS, (x + w) * SS, (y + h) * SS], radius=w * 0.1 * SS, outline=c, width=int(lw * SS))
    d.rounded_rectangle([(x + w * 0.08) * SS, y * SS, (x + w * 0.34) * SS, (y + h * 0.3) * SS], radius=2 * SS, outline=c, width=int(lw * 0.8 * SS))
    d.ellipse([(x + w * 0.14) * SS, (y + h * 0.07) * SS, (x + w * 0.2) * SS, (y + h * 0.23) * SS], outline=c, width=int(lw * 0.6 * SS))
    d.ellipse([(x + w * 0.23) * SS, (y + h * 0.07) * SS, (x + w * 0.29) * SS, (y + h * 0.23) * SS], outline=c, width=int(lw * 0.6 * SS))
    d.ellipse([(cx + w * 0.18) * SS, (cy + h * 0.08) * SS, (cx + w * 0.32) * SS, (cy + h * 0.34) * SS], outline=c, width=int(lw * 0.7 * SS))


def draw_album(d, cx, cy, w, color, alpha=255, lw=7):
    c = color[:3] + (alpha,)
    h = w * 0.8
    x, y = cx - w / 2, cy - h / 2
    d.rounded_rectangle([(x + w * 0.1) * SS, y * SS, (x + w) * SS, (y + h * 0.86) * SS], radius=w * 0.12 * SS, outline=c, width=int(lw * SS))
    d.rounded_rectangle([x * SS, (y + h * 0.14) * SS, (x + w * 0.9) * SS, (y + h) * SS], radius=w * 0.12 * SS, fill=PAPER + (alpha,) if color == INK else c, outline=c, width=int(lw * SS))
    d.ellipse([(x + w * 0.16) * SS, (y + h * 0.26) * SS, (x + w * 0.34) * SS, (y + h * 0.44) * SS], fill=c)
    d.polygon([((x + w * 0.14) * SS, (y + h * 0.82) * SS), ((x + w * 0.44) * SS, (y + h * 0.5) * SS), ((x + w * 0.72) * SS, (y + h * 0.82) * SS)], fill=c)


def draw_folder(d, cx, cy, w, color, alpha=255, lw=7):
    c = color[:3] + (alpha,)
    h = w * 0.78
    x, y = cx - w / 2, cy - h / 2
    d.rounded_rectangle([x * SS, y * SS, (x + w * 0.44) * SS, (y + h * 0.2) * SS], radius=w * 0.06 * SS, fill=c)
    d.rounded_rectangle([x * SS, (y + h * 0.08) * SS, (x + w) * SS, (y + h) * SS], radius=w * 0.09 * SS, outline=c, width=int(lw * SS))


def draw_cloud(d, cx, cy, w, color, alpha=255, lw=7):
    c = color[:3] + (alpha,)
    h = w * 0.64
    x, y = cx - w / 2, cy - h / 2
    d.arc([x * SS, (y + h * 0.28) * SS, (x + w * 0.52) * SS, (y + h * 0.94) * SS], 90, 290, fill=c, width=int(lw * SS))
    d.arc([(x + w * 0.3) * SS, y * SS, (x + w * 0.86) * SS, (y + h * 0.72) * SS], 150, 340, fill=c, width=int(lw * SS))
    d.arc([(x + w * 0.58) * SS, (y + h * 0.3) * SS, (x + w) * SS, (y + h * 0.95) * SS], 250, 90, fill=c, width=int(lw * SS))
    d.line([pt(x + w * 0.26, y + h * 0.92), pt(x + w * 0.74, y + h * 0.92)], fill=c, width=int(lw * SS))


def draw_phone(w, h, t_local=0.0, badge=0):
    """iPhone mock with mini CamSync home screen; returns sprite of size w×h design px."""
    spr = Image.new("RGBA", (int(w * SS), int(h * SS)), (0, 0, 0, 0))
    dd = ImageDraw.Draw(spr)
    # body
    dd.rounded_rectangle([0, 0, spr.width, spr.height], radius=w * 0.13 * SS, fill=INK + (255,))
    dd.rounded_rectangle([w * 0.055 * SS, h * 0.022 * SS, w * 0.945 * SS, h * 0.978 * SS], radius=w * 0.1 * SS, fill=PAPER + (255,))
    # dynamic island
    dd.rounded_rectangle([w * 0.38 * SS, h * 0.036 * SS, w * 0.62 * SS, h * 0.058 * SS], radius=h * 0.012 * SS, fill=INK + (255,))
    # status
    draw_text(dd, (w * 0.16, h * 0.052), "09:41", "latb", w * 0.055, INK, anchor="lm")
    # app title
    draw_text(dd, (w * 0.09, h * 0.1), "CamSync", "latb", w * 0.082, INK, anchor="la")
    # card
    cy0 = h * 0.155
    dd.rounded_rectangle([w * 0.07 * SS, cy0 * SS, w * 0.93 * SS, (cy0 + h * 0.13) * SS], radius=w * 0.07 * SS, fill=WHITE + (255,), outline=LINE + (255,), width=SS)
    draw_camera(dd, w * 0.19, cy0 + h * 0.065, w * 0.15, INK, lw=5)
    draw_text(dd, (w * 0.32, cy0 + h * 0.045), "连接你的相机", "zhb", w * 0.062, INK, anchor="lm")
    draw_text(dd, (w * 0.32, cy0 + h * 0.093), "相机 · SD 卡 · 外部存储", "zh", w * 0.046, MUTED, anchor="lm")
    # blue button
    by = cy0 + h * 0.16
    dd.rounded_rectangle([w * 0.07 * SS, by * SS, w * 0.93 * SS, (by + h * 0.075) * SS], radius=h * 0.0375 * SS, fill=IOS_BLUE + (255,))
    draw_text(dd, (w * 0.5, by + h * 0.0375), "选择已连接的设备", "zhb", w * 0.058, WHITE, anchor="mm")
    # history card
    hy = by + h * 0.105
    dd.rounded_rectangle([w * 0.07 * SS, hy * SS, w * 0.93 * SS, (hy + h * 0.075) * SS], radius=w * 0.06 * SS, fill=WHITE + (255,), outline=LINE + (255,), width=SS)
    circle(dd, w * 0.16, hy + h * 0.0375, w * 0.045, outline=MUTED, width=4 * SS)
    draw_text(dd, (w * 0.27, hy + h * 0.024), "历史设备", "zhb", w * 0.052, INK, anchor="lm")
    draw_text(dd, (w * 0.27, hy + h * 0.056), "共 12 台 · 上次昨天", "zh", w * 0.042, MUTED, anchor="lm")
    # empty state hint
    ey = h * 0.6
    dd.rounded_rectangle([w * 0.3 * SS, ey * SS, w * 0.7 * SS, (ey + h * 0.09) * SS], radius=w * 0.05 * SS, outline=(200, 200, 196, 255), width=2 * SS)
    dd.arc([w * 0.36 * SS, (ey + h * 0.028) * SS, w * 0.5 * SS, (ey + h * 0.062) * SS], 180, 360, fill=(170, 170, 166, 255), width=2 * SS)
    dd.line([pt(w * 0.33, ey + h * 0.062), pt(w * 0.67, ey + h * 0.062)], fill=(170, 170, 166, 255), width=2 * SS)
    draw_text(dd, (w * 0.5, ey + h * 0.13), "连接后,照片会出现在这里", "zh", w * 0.045, (160, 160, 156, 255), anchor="mm")
    # bottom tab bar
    ty = h * 0.905
    th = h * 0.075
    dd.rounded_rectangle([w * 0.07 * SS, ty * SS, w * 0.93 * SS, (ty + th) * SS], radius=th * 0.5 * SS, fill=WHITE + (255,), outline=LINE + (255,), width=SS)
    circle(dd, w * 0.3, ty + th * 0.3, w * 0.028, fill=IOS_BLUE)
    draw_text(dd, (w * 0.3, ty + th * 0.72), "浏览", "zh", w * 0.036, IOS_BLUE, anchor="mm")
    circle(dd, w * 0.7, ty + th * 0.3, w * 0.026, outline=MUTED, width=2 * SS)
    draw_text(dd, (w * 0.7, ty + th * 0.72), "记录", "zh", w * 0.036, MUTED, anchor="mm")
    # incoming badge
    if badge > 0:
        bs = 1.0 + 0.25 * max(0.0, 1 - t_local * 3)
        r = w * 0.075 * bs
        bx, byy = w * 0.85, cy0 + h * 0.02
        circle(dd, bx, byy, r, fill=ORANGE)
        draw_text(dd, (bx, byy), f"+{badge}", "latb", w * 0.062, WHITE, anchor="mm")
    return spr


# ---------------------------------------------------------------- chrome


def chrome(base, t, dark=False):
    ov = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    ink = PAPER if dark else INK
    muted = mixc(PAPER, INK, 0.45) if not dark else mixc(INK, PAPER, 0.45)
    t00 = remap(t, 0.2, 1.0)
    a = ca(255 * ease_out_cubic(t00))
    circle(d, 76, 96, 6, fill=ORANGE + (a,))
    tracked_caps(d, (100, 96), "FROM CAMERA. TO LIFE.", 21, ink + (a,), tracking=3.4, anchor="l")
    tracked_caps(d, (W - 70, 96), "CAMSYNC®", 21, muted + (a,), tracking=2.2, anchor="r")
    # bottom progress
    py = 1848
    d.line([pt(90, py), pt(990, py)], fill=(ink[0], ink[1], ink[2], 40), width=3 * SS)
    prog = clamp(t / DUR)
    if prog > 0:
        d.line([pt(90, py), pt(90 + 900 * prog, py)], fill=ORANGE + (a,), width=3 * SS)
        circle(d, 90 + 900 * prog, py, 6, fill=ORANGE + (a,))
    tracked_caps(d, (990, py + 30), "iOS · PHOTO TRANSFER", 17, muted + (int(a * 0.8),), tracking=2.6, anchor="r")
    base.alpha_composite(ov)


def scene_header(base, num, title, sub, u, dark=False):
    ov = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    ink = PAPER if dark else INK
    muted = mixc(PAPER, (90, 93, 88), 0.35) if not dark else mixc(INK, PAPER, 0.5)
    a1 = ease_out_cubic(remap(u, 0.02, 0.22))
    a2 = ease_out_cubic(remap(u, 0.1, 0.3))
    a3 = ease_out_cubic(remap(u, 0.16, 0.38))
    dy1 = (1 - a1) * 36
    # ghost number
    draw_text(d, (72, 300 + (1 - a1) * 30), num, "cond", 200, (ink[0], ink[1], ink[2], ca(26 * a1 / 255)), anchor="ls")
    draw_text(d, (90, 560 + dy1), title, "zhb", 64, ink + (ca(255 * a1),), anchor="lm")
    circle(d, 90 + text_w(d, title, font("zhb", 64)) + 36, 560, 7, fill=ORANGE + (ca(255 * a1),))
    draw_text(d, (90, 632), sub, "zh", 30, muted + (ca(255 * a2),), anchor="lm")
    d.line([pt(90, 688), pt(990, 688)], fill=(ink[0], ink[1], ink[2], ca(60 * a3 / 255)), width=SS)
    base.alpha_composite(ov)
    return a3


# ---------------------------------------------------------------- scenes

SCENES = []


def scene(t0, t1, fn):
    SCENES.append({"t0": t0, "t1": t1, "fn": fn})


# ---- S0 hook (ink) ----


def s0(u, t):
    base = Image.new("RGBA", (W * SS, H * SS), INK + (255,))
    ov = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov, "RGBA")
    a = fade_alpha(u, 0.0, 0.14)
    # sd card
    t_sd = ease_out_back(remap(u, 0.04, 0.34))
    bob = math.sin(t * 2.1) * 4
    if t_sd > 0:
        draw_sd(d, W / 2, 1180 + bob + (1 - t_sd) * 160, 150 * clamp(t_sd, 0.3, 1), PAPER, alpha=ca(255 * a * clamp(t_sd * 2, 0, 1)), lw=8)
    # photos popping out
    n = 5
    for i in range(n):
        ti = remap(u, 0.16 + i * 0.09, 0.5 + i * 0.09)
        if ti <= 0:
            continue
        e = ease_out_back(ti)
        ang = math.pi * (0.15 + 0.7 * i / (n - 1))
        radius = 300 * ease_out_cubic(ti)
        cx = W / 2 + math.cos(math.pi + ang) * radius * 1.35
        cy = 1180 + bob - math.sin(ang) * radius * 1.3 - 100 * ease_out_cubic(ti)
        scale = 0.42 * e
        paste_sprite(ov, photo_sprite(int(210 * SS), i % 6, i % 3), cx, cy, scale, math.sin(t * 1.4 + i) * 4, alpha=ca(255 * a * clamp(ti * 2, 0, 1)))
    # headline
    a1 = ease_out_cubic(remap(u, 0.42, 0.68))
    a2 = ease_out_cubic(remap(u, 0.55, 0.82))
    draw_text(d, (90, 260 + (1 - a1) * 40), "拍了很多好照片,", "zhb", 74, PAPER + (ca(255 * a1),), anchor="lm")
    draw_text(d, (90, 368 + (1 - a2) * 40), "然后呢?", "zhb", 96, ORANGE + (ca(255 * a2),), anchor="lm")
    tracked_caps(d, (90, 478), "PHOTOS, STUCK IN YOUR CAMERA.", 20, mixc(INK, PAPER, 0.5) + (ca(255 * a2),), tracking=2.6, anchor="l")
    # route line bottom
    pts = [(90, 1500), (300, 1420), (540, 1500), (780, 1420), (990, 1500)]
    dashed_path(d, pts, PAPER, 2.5, dash=9, gap=13, alpha=ca(70 * a / 255))
    dot_t = (t * 0.25) % 1
    seg = min(int(dot_t * (len(pts) - 1)), len(pts) - 2)
    ft = dot_t * (len(pts) - 1) - seg
    dx, dy = qbez(pts[seg], ((pts[seg][0] + pts[seg + 1][0]) / 2, min(pts[seg][1], pts[seg + 1][1]) - 60), pts[seg + 1], ft)
    circle(d, dx, dy, 8, fill=ORANGE + (ca(255 * a),))
    base.alpha_composite(ov)
    return base


# ---- S1 brand (paper) ----


def s1(u, t):
    base = Image.new("RGBA", (W * SS, H * SS), PAPER + (255,))
    ov = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov, "RGBA")
    a = fade_alpha(u, 0.1, 0.1)
    # faint dashed route behind
    pts = [(60, 1310), (280, 1230), (540, 1310), (800, 1230), (1020, 1310)]
    dashed_path(d, pts, INK, 2.5, alpha=ca(40 * a / 255))
    # icon
    e_icon = ease_out_back(remap(u, 0.05, 0.4))
    bob = math.sin(t * 1.8) * 5
    paste_icon(ov, W / 2, 760 + bob, 220, scale=max(0.001, e_icon), alpha=ca(255 * a))
    # wordmark
    a1 = ease_out_cubic(remap(u, 0.32, 0.58))
    if a1 > 0:
        wm = "CamSync"
        f = font("latb", 92)
        wwm = text_w(d, wm, f, tracking=-2)
        draw_text(d, (W / 2 - wwm / 2, 960 + (1 - a1) * 30), wm, "latb", 92, INK + (ca(255 * a1),), tracking=-2)
        draw_text(d, (W / 2 + wwm / 2 + 14, 972 + (1 - a1) * 30), "®", "lat", 26, MUTED + (ca(255 * a1),))
    # tagline
    a2 = ease_out_cubic(remap(u, 0.48, 0.74))
    tg = "让照片,继续出发"
    tgw = text_w(d, tg, font("zhb", 44))
    draw_text(d, (W / 2 - 20, 1085 + (1 - a2) * 24), tg, "zhb", 44, INK + (ca(255 * a2),), anchor="mm")
    if a2 > 0.1:
        arrow_ne(d, W / 2 - 20 + tgw / 2 + 40, 1078, 34, ORANGE, 6, alpha=ca(255 * a2))
    # sub
    a3 = ease_out_cubic(remap(u, 0.6, 0.85))
    draw_text(d, (W / 2, 1180), "把相机里的照片,带进 iPhone 相册、", "zh", 29, MUTED + (ca(255 * a3),), anchor="mm")
    draw_text(d, (W / 2, 1224), "文件夹或 iCloud Drive。", "zh", 29, MUTED + (ca(255 * a3),), anchor="mm")
    # three floating chips
    chips = [("相机", draw_camera), ("SD 卡", draw_sd), ("USB", draw_usb)]
    for i, (label, fn_i) in enumerate(chips):
        ti = ease_out_back(remap(u, 0.66 + i * 0.08, 0.86 + i * 0.08))
        if ti <= 0:
            continue
        cxx = W / 2 + (i - 1) * 245
        cyy = 1440 + math.sin(t * 1.6 + i * 2) * 8
        alpha = ca(255 * a)
        shadow(d, cxx - 85 + 7, cyy - 48 + 7, 170, 96, r=28, off=0, color=(32, 35, 31, ca(24 * a / 255)))
        rect_box(d, cxx - 85, cyy - 48, 170, 96, r=28, fill=WHITE + (alpha,), outline=LINE + (alpha,), width=SS)
        fn_i(d, cxx, cyy - 14, 50 * clamp(ti, 0.4, 1), INK, alpha=alpha, lw=6)
        draw_text(d, (cxx, cyy + 28), label, "zh", 22, MUTED + (alpha,), anchor="mm")
    base.alpha_composite(ov)
    return base


# ---- S2 connect (paper) ----


def s2(u, t):
    base = Image.new("RGBA", (W * SS, H * SS), PAPER + (255,))
    ov = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov, "RGBA")
    a = fade_alpha(u, 0.08, 0.12)
    scene_header(base, "01", "连接你的灵感", "相机、读卡器、USB 存储,在「文件」里就能看到。", u)
    badge_n = 0
    badge_tl = 9
    # device card (left)
    e1 = ease_out_back(remap(u, 0.2, 0.42))
    if e1 > 0:
        cxx, cyy = 265, 1020
        s = clamp(e1, 0.2, 1)
        alpha = ca(255 * a)
        shadow(d, cxx - 150 + 8, cyy - 110 + 8, 300, 220, r=32, off=0, color=(32, 35, 31, ca(24 * alpha / 255)))
        rect_box(d, cxx - 150, cyy - 110, 300, 220, r=32, fill=WHITE + (alpha,), outline=LINE + (alpha,), width=SS)
        draw_camera(d, cxx, cyy - 25, 96 * s, INK, alpha=alpha, lw=7)
        draw_text(d, (cxx, cyy + 62), "你的相机", "zhb", 27, INK + (alpha,), anchor="mm")
        for i, (lab, fn_i) in enumerate([("SD", draw_sd), ("USB", draw_usb)]):
            ti = ease_out_back(remap(u, 0.3 + i * 0.1, 0.5 + i * 0.1))
            if ti <= 0:
                continue
            yy = 1300 + i * 130
            xx = 265
            alpha2 = ca(255 * a)
            shadow(d, xx - 105 + 6, yy - 52 + 6, 210, 104, r=24, off=0, color=(32, 35, 31, ca(20 * alpha2 / 255)))
            rect_box(d, xx - 105, yy - 52, 210, 104, r=24, fill=WHITE + (alpha2,), outline=LINE + (alpha2,), width=SS)
            fn_i(d, xx - 55, yy, 40 * clamp(ti, 0.4, 1), INK, alpha=alpha2, lw=6)
            draw_text(d, (xx + 32, yy), lab, "latb", 24, INK + (alpha2,), anchor="mm")
    # phone (right)
    e2 = ease_out_back(remap(u, 0.26, 0.5))
    ph_x, ph_y, ph_w, ph_h = 700, 800, 340, 700
    if e2 > 0.01:
        spr = draw_phone(ph_w, ph_h, t, badge=0)
        paste_sprite(ov, spr, ph_x + ph_w / 2, ph_y + ph_h / 2, scale=clamp(e2, 0.2, 1), alpha=ca(255 * a))
    # connection line + flying photos
    e3 = ease_out_cubic(remap(u, 0.42, 0.6))
    if e3 > 0:
        p0 = (430, 1000)
        p1 = (580, 1160)
        p2 = (700, 1120)
        pts = [qbez(p0, p1, p2, i / 40) for i in range(41)]
        dashed_path(d, pts, INK, 3, dash=8, gap=10, alpha=ca(150 * e3 * a / 255))
    for i in range(3):
        ti = remap(u, 0.46 + i * 0.14, 0.72 + i * 0.14)
        if ti <= 0 or ti >= 1.35:
            continue
        if ti >= 1:
            badge_n = i + 1
            badge_tl = u - (0.72 + i * 0.14)
            continue
        e = ease_in_out_quint(ti)
        pos = qbez((430, 1000), (580, 1180), (760, 1150), e)
        scale = lerp(0.5, 0.12, e)
        paste_sprite(ov, photo_sprite(int(200 * SS), i * 2 % 6, i % 3), pos[0], pos[1], scale, math.sin(ti * math.pi) * -14, alpha=ca(255 * a * (1 - max(0, ti - 0.85) / 0.15)))
    if badge_n > 0:
        spr = draw_phone(ph_w, ph_h, badge_tl, badge=badge_n)
        paste_sprite(ov, spr, ph_x + ph_w / 2, ph_y + ph_h / 2, scale=1.0, alpha=ca(255 * a * (1 - remap(u, 0.9, 1.0))))
    # caption
    a4 = ease_out_cubic(remap(u, 0.72, 0.9))
    if a4 > 0:
        cxx, cyy = W / 2, 1660
        label = "系统文件选择器授权 · 安全不越界"
        tw = text_w(d, label, font("zh", 27)) + 56
        rect_box(d, cxx - tw / 2, cyy - 34, tw, 68, r=34, fill=WHITE + (ca(255 * a4),), outline=LINE + (ca(255 * a4),), width=SS)
        circle(d, cxx - tw / 2 + 34, cyy, 5, fill=ORANGE + (ca(255 * a4),))
        draw_text(d, (cxx - tw / 2 + 56, cyy), label, "zh", 27, INK + (ca(255 * a4),), anchor="lm")
    base.alpha_composite(ov)
    return base


# ---- S3 select (paper) ----


def s3(u, t):
    base = Image.new("RGBA", (W * SS, H * SS), PAPER + (255,))
    ov = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov, "RGBA")
    scene_header(base, "02", "挑选值得留下的", "已选、新增、全部、时间段,四种方式任你挑。", u)
    # 3x3 grid
    gs = 232
    gap = 26
    x0 = (W - 3 * gs - 2 * gap) / 2
    y0 = 770
    sel = [0, 2, 3, 4, 7]
    checks = 0
    for i in range(9):
        row, col = divmod(i, 3)
        x = x0 + col * (gs + gap)
        y = y0 + row * (gs + gap)
        ti = ease_out_back(remap(u, 0.16 + i * 0.035, 0.36 + i * 0.035))
        if ti <= 0:
            continue
        s = clamp(ti, 0.2, 1)
        alpha = ca(255 * fade_alpha(u, 0.06, 0.12))
        cx, cy = x + gs / 2, y + gs / 2
        chosen = i in sel
        ct = ease_out_back(remap(u, 0.44 + sel.index(i) * 0.07, 0.58 + sel.index(i) * 0.07)) if chosen else 0
        if chosen and ct > 0:
            s *= 1 + 0.06 * math.sin(min(ct, 1) * math.pi)
            ring_a = ca(255 * ct)
            rect_box(d, x - 7, y - 7, gs + 14, gs + 14, r=36, outline=ORANGE + (ring_a,), width=5 * SS)
        shadow(d, x + 7, y + 7, gs, gs, r=28, off=0, color=(32, 35, 31, ca(20 * alpha / 255)))
        rect_box(d, x, y, gs, gs, r=28, fill=WHITE + (alpha,), outline=LINE + (alpha,), width=SS)
        ph_in = int((gs - 36) * SS)
        spr = photo_sprite(ph_in, i % 6, (i * 2 + 1) % 3)
        ov.alpha_composite(spr, (int((x + 18) * SS), int((y + 18) * SS)))
        if chosen and ct > 0:
            r = 30 * clamp(ct, 0.3, 1)
            circle(d, x + gs - 34, y + 34, r, fill=ORANGE + (ca(255 * ct),))
            check_mark(d, x + gs - 34, y + 34, 26, WHITE, 6, prog=clamp(ct * 1.4, 0, 1))
            checks += 1
    # chips
    chips = ["已选", "新增", "全部", "时间段"]
    cy = 1630
    widths = [text_w(d, c, font("zhb", 30)) + 76 for c in chips]
    total = sum(widths) + 24 * (len(chips) - 1)
    cx = (W - total) / 2
    active = int(t / 0.9) % 4
    for i, c in enumerate(chips):
        ti = ease_out_back(remap(u, 0.6 + i * 0.06, 0.74 + i * 0.06))
        if ti <= 0:
            cx += widths[i] + 24
            continue
        is_on = i == active and u > 0.62
        pulse = 1 + (0.05 * math.sin(t * 4) if is_on else 0)
        alpha = ca(255 * fade_alpha(u, 0.06, 0.12) * clamp(ti, 0.3, 1))
        w_i = widths[i] * pulse
        h_i = 74 * pulse
        if is_on:
            rect_box(d, cx - (w_i - widths[i]) / 2, cy - h_i / 2, w_i, h_i, r=h_i / 2, fill=ORANGE + (alpha,))
            draw_text(d, (cx, cy), c, "zhb", 30, WHITE + (alpha,), anchor="mm")
        else:
            rect_box(d, cx - (w_i - widths[i]) / 2, cy - h_i / 2, w_i, h_i, r=h_i / 2, fill=WHITE + (alpha,), outline=LINE + (alpha,), width=SS)
            draw_text(d, (cx, cy), c, "zhb", 30, INK + (alpha,), anchor="mm")
        cx += widths[i] + 24
    # caption
    a4 = ease_out_cubic(remap(u, 0.8, 0.95))
    draw_text(d, (W / 2, 1745), "先挑照片,再决定保存位置", "zh", 27, MUTED + (ca(255 * a4 * fade_alpha(u, 0.06, 0.12)),), anchor="mm")
    base.alpha_composite(ov)
    return base


# ---- S4 save (paper) ----


def s4(u, t):
    base = Image.new("RGBA", (W * SS, H * SS), PAPER + (255,))
    ov = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov, "RGBA")
    scene_header(base, "03", "去你想去的地方", "系统相册 · 本机文件夹 · iCloud Drive", u)
    # big counter
    cnt_e = ease_in_out_quint(remap(u, 0.22, 0.62))
    cnt = int(round(cnt_e * 100))
    a = ca(255 * fade_alpha(u, 0.06, 0.12))
    if cnt_e > 0:
        f = font("latb", 150)
        num = f"{cnt}"
        nw = text_w(d, num, f)
        cx = W / 2 - 34
        draw_text(d, (cx - nw / 2, 870), num, "latb", 150, ORANGE + (a,), anchor="lm")
        draw_text(d, (cx + nw / 2 + 26, 850), "张", "zhb", 40, INK + (a,), anchor="lm")
        tracked_caps(d, (cx + nw / 2 + 26, 902), "1 MIN", 24, MUTED + (a,), tracking=2.4, anchor="l")
    # destination cards
    cards = [
        ("系统相册", draw_album),
        ("本机文件夹", draw_folder),
        ("iCloud Drive", draw_cloud),
    ]
    cw, ch = 272, 330
    gap = 26
    x0 = (W - 3 * cw - 2 * gap) / 2
    y0 = 1080
    centers = []
    for i, (label, icon_fn) in enumerate(cards):
        x = x0 + i * (cw + gap)
        ti = ease_out_back(remap(u, 0.34 + i * 0.09, 0.56 + i * 0.09))
        centers.append((x + cw / 2, y0 + ch / 2))
        if ti <= 0:
            continue
        s = clamp(ti, 0.2, 1)
        alpha = a
        shadow(d, x + 7, y0 + 7, cw, ch, r=30, off=0, color=(32, 35, 31, ca(20 * alpha / 255)))
        rect_box(d, x, y0, cw, ch, r=30, fill=WHITE + (alpha,), outline=LINE + (alpha,), width=SS)
        icon_fn(d, x + cw / 2, y0 + 105, 110 * clamp(ti, 0.4, 1), INK, alpha=alpha, lw=7)
        draw_text(d, (x + cw / 2, y0 + 205), label, "zhb", 28, INK + (alpha,), anchor="mm")
        done = ease_out_cubic(remap(u, 0.6 + i * 0.06, 0.72 + i * 0.06))
        if done > 0:
            circle(d, x + cw / 2, y0 + 262, 16 * clamp(done, 0.3, 1), fill=ORANGE + (ca(255 * done * a),))
            check_mark(d, x + cw / 2, y0 + 262, 15, WHITE, 4.5, prog=clamp(done * 1.5, 0, 1))
    # photos flying in from the left edge
    for i in range(6):
        card_i = i % 3
        ti = remap(u, 0.36 + i * 0.055, 0.62 + i * 0.055)
        if ti <= 0 or ti >= 1:
            continue
        e = ease_in_out_quint(ti)
        pos = qbez((30, 1250), ((30 + centers[card_i][0]) / 2, 1010 - card_i * 60), centers[card_i], e)
        scale = lerp(0.4, 0.1, e)
        paste_sprite(ov, photo_sprite(int(200 * SS), (i * 5) % 6, i % 3), pos[0], pos[1], scale, lerp(-24, 0, e), alpha=int(a * (1 - max(0, ti - 0.8) / 0.2)))
    # caption
    a4 = ease_out_cubic(remap(u, 0.78, 0.94))
    draw_text(d, (W / 2, 1690), "写入成功才算完成 · 保留来源目录结构", "zh", 27, MUTED + (ca(255 * a4 * fade_alpha(u, 0.06, 0.12)),), anchor="mm")
    base.alpha_composite(ov)
    return base


# ---- S5 trust (ink) ----


def s5(u, t):
    base = Image.new("RGBA", (W * SS, H * SS), INK + (255,))
    ov = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov, "RGBA")
    a = ca(255 * fade_alpha(u, 0.08, 0.14))
    # headline
    a1 = ease_out_cubic(remap(u, 0.06, 0.26))
    a2 = ease_out_cubic(remap(u, 0.14, 0.34))
    draw_text(d, (90, 560 + (1 - a1) * 40), "确实存好,", "zhb", 88, PAPER + (ca(255 * a1),), anchor="lm")
    draw_text(d, (90, 680 + (1 - a2) * 40), "才算完成。", "zhb", 88, ORANGE + (ca(255 * a2),), anchor="lm")
    # progress bar
    e = ease_in_out_quint(remap(u, 0.28, 0.66))
    py = 900
    d.line([pt(90, py), pt(990, py)], fill=(PAPER[0], PAPER[1], PAPER[2], ca(50 * a / 255)), width=8 * SS)
    if e > 0:
        d.line([pt(90, py), pt(90 + 900 * e, py)], fill=ORANGE + (a,), width=8 * SS)
        circle(d, 90 + 900 * e, py, 9 * clamp(e * 2, 0.3, 1), fill=ORANGE + (a,))
    draw_text(d, (90, 960), "SYNCED", "lat", 24, mixc(INK, PAPER, 0.5) + (a,), anchor="lm", tracking=3)
    draw_text(d, (990, 960), f"{int(e * 100)} / 100", "latb", 28, PAPER + (ca(255 * a * ease_out_cubic(remap(u, 0.3, 0.5))),), anchor="rm")
    if e >= 1:
        cp = ease_out_back(remap(u, 0.66, 0.76))
        if cp > 0:
            circle(d, 990, py, 26 * clamp(cp, 0.3, 1), fill=ORANGE)
            check_mark(d, 990, py, 22, WHITE, 6, prog=clamp(cp * 1.4, 0, 1))
    # three pills
    items = ["无需账号", "没有广告", "数据本地处理"]
    widths = [text_w(d, it, font("zhb", 30)) + 100 for it in items]
    total = sum(widths) + 22 * (len(items) - 1)
    cx = (W - total) / 2
    for i, it in enumerate(items):
        ti = ease_out_back(remap(u, 0.44 + i * 0.08, 0.62 + i * 0.08))
        if ti <= 0:
            cx += widths[i] + 22
            continue
        alpha = ca(255 * a * clamp(ti, 0.3, 1))
        rect_box(d, cx, 1078, widths[i], 104, r=52, fill=(46, 49, 45) + (alpha,), outline=(74, 77, 72) + (alpha,), width=SS)
        circle(d, cx + 52, 1130, 22 * clamp(ti, 0.3, 1), fill=ORANGE + (alpha,))
        check_mark(d, cx + 52, 1130, 19, PAPER, 5, prog=clamp(ti * 1.3, 0, 1))
        draw_text(d, (cx + 92, 1130), it, "zhb", 30, PAPER + (alpha,), anchor="lm")
        cx += widths[i] + 22
    # sub lines
    a3 = ease_out_cubic(remap(u, 0.62, 0.82))
    draw_text(d, (W / 2, 1330), "失败有记录,重连后可继续。", "zh", 30, mixc(INK, PAPER, 0.55) + (ca(255 * a3),), anchor="mm")
    draw_text(d, (W / 2, 1382), "不会重复复制,不占多余空间。", "zh", 30, mixc(INK, PAPER, 0.55) + (ca(255 * a3),), anchor="mm")
    # heart line
    pts = [(90, 1560), (300, 1480), (540, 1560), (780, 1480), (990, 1560)]
    dashed_path(d, pts, PAPER, 2.5, alpha=ca(60 * a / 255))
    base.alpha_composite(ov)
    return base


# ---- S6 outro (paper) ----


def s6(u, t):
    base = Image.new("RGBA", (W * SS, H * SS), PAPER + (255,))
    ov = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov, "RGBA")
    a = ca(255 * fade_alpha(u, 0.06, 0.0))  # hold to end
    # icon
    e0 = ease_out_back(remap(u, 0.04, 0.3))
    bob = math.sin(t * 1.6) * 5
    paste_icon(ov, W / 2, 640 + bob, 240, scale=max(0.001, e0), alpha=255)
    # wordmark
    a1 = ease_out_cubic(remap(u, 0.24, 0.44))
    wm = "CamSync"
    f = font("latb", 100)
    wwm = text_w(d, wm, f, tracking=-2.5)
    draw_text(d, (W / 2 - wwm / 2, 900 + (1 - a1) * 30), wm, "latb", 100, INK + (ca(255 * a1),), tracking=-2.5)
    draw_text(d, (W / 2 + wwm / 2 + 16, 916 + (1 - a1) * 30), "®", "lat", 28, MUTED + (ca(255 * a1),))
    # tagline
    a2 = ease_out_cubic(remap(u, 0.36, 0.56))
    tg = "让照片,继续出发"
    tgw = text_w(d, tg, font("zhb", 48))
    draw_text(d, (W / 2 - 24, 1058), tg, "zhb", 48, INK + (ca(255 * a2),), anchor="mm")
    if a2 > 0.1:
        arrow_ne(d, W / 2 - 24 + tgw / 2 + 44, 1050, 36, ORANGE, 7, alpha=ca(255 * a2))
    # store pill
    e3 = ease_out_back(remap(u, 0.5, 0.7))
    if e3 > 0:
        pulse = 1 + 0.02 * math.sin((t - 33.9) * 3.2)
        label = "App Store 搜索「CamSync」"
        tw = text_w(d, label, font("zhb", 40)) + 110
        pw, ph = tw * pulse, 108 * pulse
        alpha = ca(255 * clamp(e3, 0.3, 1))
        sh = Image.new("RGBA", base.size, (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle(box(W / 2 - pw / 2 + 8, 1210 - ph / 2 + 10, pw, ph), radius=ph / 2 * SS, fill=(32, 35, 31, 60))
        ov.alpha_composite(sh.filter(ImageFilter.GaussianBlur(10 * SS)))
        rect_box(d, W / 2 - pw / 2, 1210 - ph / 2, pw, ph, r=ph / 2, fill=ORANGE + (alpha,))
        draw_text(d, (W / 2, 1210), label, "zhb", 40, WHITE + (alpha,), anchor="mm")
    # meta
    a4 = ease_out_cubic(remap(u, 0.62, 0.8))
    draw_text(d, (W / 2, 1350), "iOS 17.0+ · iPhone · 中文可用", "zh", 26, MUTED + (ca(255 * a4),), anchor="mm")
    # dashed route + moving dot
    pts = [(90, 1520), (300, 1440), (540, 1520), (780, 1440), (990, 1520)]
    dashed_path(d, pts, INK, 2.5, alpha=ca(50 * a4 / 255))
    dot_t = (t * 0.22) % 1
    seg = min(int(dot_t * (len(pts) - 1)), len(pts) - 2)
    ft = dot_t * (len(pts) - 1) - seg
    dx, dy = qbez(pts[seg], ((pts[seg][0] + pts[seg + 1][0]) / 2, min(pts[seg][1], pts[seg + 1][1]) - 56), pts[seg + 1], ft)
    circle(d, dx, dy, 8, fill=ORANGE + (ca(255 * a4),))
    tracked_caps(d, (W / 2, 1650), "MADE FOR THE MOMENTS.", 22, MUTED + (ca(255 * a4),), tracking=3.4)
    base.alpha_composite(ov)
    return base


scene(0.0, 4.3, s0)
scene(4.3, 8.1, s1)
scene(8.1, 14.6, s2)
scene(14.6, 21.1, s3)
scene(21.1, 27.6, s4)
scene(27.6, 31.9, s5)
scene(31.9, 37.0, s6)

WIPES = [
    (4.3, 0.42, 0.36),  # S0 -> S1
    (27.6, 0.42, 0.36),  # S4 -> S5
]


def circle_wipe_overlay(base, t):
    for center_t, r_out, r_in in WIPES:
        if center_t - r_out <= t < center_t:
            k = ease_in_out_quint(remap(t, center_t - r_out, center_t))
            r = k * 1450
            ov = Image.new("RGBA", base.size, (0, 0, 0, 0))
            ImageDraw.Draw(ov).ellipse([W / 2 * SS - r * SS, 1050 * SS - r * SS, W / 2 * SS + r * SS, 1050 * SS + r * SS], fill=ORANGE + (255,))
            base.alpha_composite(ov)
        elif center_t <= t < center_t + r_in:
            k = 1 - ease_in_out_quint(remap(t, center_t, center_t + r_in))
            r = k * 1450
            if r > 1:
                ov = Image.new("RGBA", base.size, (0, 0, 0, 0))
                ImageDraw.Draw(ov).ellipse([W / 2 * SS - r * SS, 1050 * SS - r * SS, W / 2 * SS + r * SS, 1050 * SS + r * SS], fill=ORANGE + (255,))
                base.alpha_composite(ov)


# ---------------------------------------------------------------- grain

_grains = []


def grain_img():
    g = Image.effect_noise((W, H), 14).convert("L").point(lambda v: 128 + (v - 128) * 0.5)
    rgba = Image.merge("RGBA", (g, g, g, g.point(lambda v: 10)))
    return rgba


def apply_grain(base, fi):
    if not _grains:
        _grains.extend(grain_img() for _ in range(3))
    base.alpha_composite(_grains[fi % 3])


# ---------------------------------------------------------------- composer


def render_frame(fi):
    t = fi / FPS
    # find active scene(s)
    idx = None
    for i, sc in enumerate(SCENES):
        if sc["t0"] <= t < sc["t1"]:
            idx = i
            break
    if idx is None:
        idx = len(SCENES) - 1 if t >= SCENES[-1]["t1"] else 0
    sc = SCENES[idx]
    u = clamp((t - sc["t0"]) / (sc["t1"] - sc["t0"]))
    img = sc["fn"](u, t).convert("RGBA")
    # crossfade at plain boundaries (wipe boundaries handled by circle wipe)
    XF = 0.28
    WIPE_AFTER = {0, 4}
    if idx + 1 < len(SCENES) and idx not in WIPE_AFTER and t > sc["t1"] - XF:
        k = ease_in_out_quint(remap(t, sc["t1"] - XF, sc["t1"]))
        nxt = SCENES[idx + 1]
        u2 = clamp((t - nxt["t0"]) / (nxt["t1"] - nxt["t0"]))
        img2 = nxt["fn"](u2, t).convert("RGBA")
        img = Image.blend(img, img2, k)
    elif idx > 0 and (idx - 1) not in WIPE_AFTER and t < sc["t0"] + XF:
        k = ease_in_out_quint(remap(t, sc["t0"], sc["t0"] + XF))
        prev = SCENES[idx - 1]
        u0 = 1.0
        img0 = prev["fn"](u0, t).convert("RGBA")
        img = Image.blend(img0, img, k)
    dark = idx in (0, 5)
    chrome(img, t, dark=dark)
    circle_wipe_overlay(img, t)
    # downsample
    frame = img.resize((W, H), Image.LANCZOS)
    apply_grain(frame, fi)
    return frame.convert("RGB")


def main():
    args = sys.argv[1:]
    out = os.path.join(ROOT, "camsync-promo-9x16.mp4")
    if "--stills" in args:
        i = args.index("--stills")
        times = [float(x) for x in args[i + 1].split(",")]
        for ts in times:
            fi = int(ts * FPS)
            render_frame(fi).save(os.path.join(ROOT, f"still_{ts:05.2f}s.png"))
            print("saved", ts)
        return
    total = int(DUR * FPS)
    cmd = [
        "ffmpeg", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-",
        "-c:v", "libx264", "-preset", "medium", "-crf", "18",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", out,
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for fi in range(total):
        proc.stdin.write(render_frame(fi).tobytes())
        if fi % 90 == 0:
            print(f"frame {fi}/{total} ({fi / FPS:.1f}s)", flush=True)
    proc.stdin.close()
    proc.wait()
    print("done:", out)


if __name__ == "__main__":
    main()
