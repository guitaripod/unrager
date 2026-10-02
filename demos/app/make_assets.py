import math
import os
import re
import shutil
import subprocess
import sys
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "assets")
MANIFEST = []
TAU = 2 * math.pi


def hx(s):
    """Hex colour string to a float32 RGB triple in 0..1."""
    s = s.lstrip("#")
    return np.array([int(s[i:i + 2], 16) / 255 for i in (0, 2, 4)], np.float32)


def mixc(a, b, t):
    """Linear blend of two colours or colour arrays."""
    return a + (b - a) * t


def X(w):
    return np.arange(w, dtype=np.float32)[None, :]


def Y(h):
    return np.arange(h, dtype=np.float32)[:, None]


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def ramp(t, stops):
    """Multi-stop colour ramp over an array of positions in 0..1."""
    pos = np.array([s[0] for s in stops], np.float32)
    cols = np.stack([hx(s[1]) for s in stops])
    out = np.empty(np.shape(t) + (3,), np.float32)
    for c in range(3):
        out[..., c] = np.interp(t, pos, cols[:, c])
    return out


def vgrad(w, h, stops):
    t = np.broadcast_to(np.linspace(0, 1, h, dtype=np.float32)[:, None], (h, w))
    return ramp(t, stops)


def lgrad(w, h, stops, angle):
    a = math.radians(angle)
    c, s = math.cos(a), math.sin(a)
    t = ((X(w) - w / 2) * c + (Y(h) - h / 2) * s) / (abs(w * c) + abs(h * s)) + .5
    return ramp(t, stops)


def sky(w, h, hz, stops):
    """Vertical gradient whose stops span the sky from the top to the horizon row hz."""
    k = hz / h
    st = [(p * k, c) for p, c in stops] + [(1.0, stops[-1][1])]
    return vgrad(w, h, st)


def _box(a, r, axis):
    n = a.shape[axis]
    pad = [(0, 0)] * a.ndim
    pad[axis] = (r + 1, r)
    c = np.cumsum(np.pad(a, pad, mode="edge"), axis=axis, dtype=np.float64)
    hi = [slice(None)] * a.ndim
    lo = [slice(None)] * a.ndim
    hi[axis] = slice(2 * r + 1, 2 * r + 1 + n)
    lo[axis] = slice(0, n)
    return ((c[tuple(hi)] - c[tuple(lo)]) / (2 * r + 1)).astype(np.float32)


def blur(a, sx, sy=None):
    """Gaussian-like blur from three box passes per axis, edge clamped."""
    sy = sx if sy is None else sy
    for s, axis in ((sx, 1), (sy, 0)):
        if s < 0.6:
            continue
        r = max(1, int(round((math.sqrt(4 * s * s + 1) - 1) / 2)))
        for _ in range(3):
            a = _box(a, r, axis)
    return a


def shift(m, dx, dy):
    out = np.zeros_like(m)
    h, w = m.shape[:2]
    dx, dy = int(dx), int(dy)
    ys, yd = (slice(0, h - dy), slice(dy, h)) if dy >= 0 else (slice(-dy, h), slice(0, h + dy))
    xs, xd = (slice(0, w - dx), slice(dx, w)) if dx >= 0 else (slice(-dx, w), slice(0, w + dx))
    out[yd, xd] = m[ys, xs]
    return out


class Pen:
    """Supersampled antialiased shape painter that yields float coverage masks."""

    def __init__(self, w, h, ss=2):
        self.w, self.h, self.ss = w, h, ss
        self.im = Image.new("L", (w * ss, h * ss), 0)
        self.d = ImageDraw.Draw(self.im)

    def _p(self, pts):
        return [(x * self.ss, y * self.ss) for x, y in pts]

    def poly(self, pts, v=255):
        self.d.polygon(self._p(pts), fill=v)

    def rect(self, x0, y0, x1, y1, v=255):
        s = self.ss
        self.d.rectangle([x0 * s, y0 * s, x1 * s - 1, y1 * s - 1], fill=v)

    def rrect(self, x0, y0, x1, y1, r, v=255):
        s = self.ss
        self.d.rounded_rectangle([x0 * s, y0 * s, x1 * s - 1, y1 * s - 1], radius=r * s, fill=v)

    def ellipse(self, cx, cy, rx, ry, v=255):
        s = self.ss
        self.d.ellipse([(cx - rx) * s, (cy - ry) * s, (cx + rx) * s, (cy + ry) * s], fill=v)

    def circle(self, cx, cy, r, v=255):
        self.ellipse(cx, cy, r, r, v)

    def ring(self, cx, cy, r, width, v=255):
        self.circle(cx, cy, r, v)
        self.circle(cx, cy, r - width, 0)

    def arch(self, x0, y0, x1, y1, v=255):
        r = (x1 - x0) / 2
        self.circle((x0 + x1) / 2, y0 + r, r, v)
        self.rect(x0, y0 + r, x1, y1, v)

    def pie(self, cx, cy, r, a0, a1, v=255):
        s = self.ss
        self.d.pieslice([(cx - r) * s, (cy - r) * s, (cx + r) * s, (cy + r) * s], a0, a1, fill=v)

    def line(self, pts, width, v=255):
        self.d.line(self._p(pts), fill=v, width=int(width * self.ss))

    def mask(self, soft=0):
        m = np.asarray(self.im.resize((self.w, self.h), Image.BOX), np.float32) / 255
        return blur(m, soft) if soft else m


def over(img, col, m, a=1.0):
    k = (m * a)[..., None]
    img[...] = img * (1 - k) + np.asarray(col, np.float32) * k


def addl(img, col, m, a=1.0):
    img += np.asarray(col, np.float32) * (m * a)[..., None]


def paper(img, m, col, dy=14, soft=16, sa=.32):
    """Paper-cut layer: soft drop shadow underneath, then the flat colour."""
    sh = blur(shift(m, 0, dy), soft)
    img *= (1 - sh * sa)[..., None]
    over(img, col, m)


def cov_below(h, w, ry):
    return np.clip(Y(h) - ry[None, :] + .5, 0, 1)


def fill_below(img, ry, top, bot, limit=None, a=1.0):
    """Fill everything under the ridge line ry with a vertical top-to-bottom colour."""
    h, w, _ = img.shape
    cov = cov_below(h, w, ry)
    if limit is not None:
        cov = cov * np.clip(limit - Y(h) + .5, 0, 1)
    y0 = float(ry.min())
    t = np.clip((Y(h) - y0) / max(1.0, h - y0), 0, 1)[..., None]
    col = np.asarray(top, np.float32) + (np.asarray(bot, np.float32) - np.asarray(top, np.float32)) * t
    over(img, col, cov, a)
    return cov


def noise1d(n, k, rng):
    pts = rng.random(k + 3).astype(np.float32)
    xs = np.linspace(0, k, n, endpoint=False, dtype=np.float32)
    i = xs.astype(int)
    f = xs - i
    f = f * f * (3 - 2 * f)
    return pts[i] * (1 - f) + pts[i + 1] * f


def noise2d(h, w, kx, ky, rng):
    g = rng.random((ky + 3, kx + 3)).astype(np.float32)
    ys = np.linspace(0, ky, h, endpoint=False, dtype=np.float32)
    xs = np.linspace(0, kx, w, endpoint=False, dtype=np.float32)
    iy, ix = ys.astype(int), xs.astype(int)
    fy, fx = ys - iy, xs - ix
    fy = (fy * fy * (3 - 2 * fy))[:, None]
    fx = (fx * fx * (3 - 2 * fx))[None, :]
    a = g[iy[:, None], ix[None, :]]
    b = g[iy[:, None], ix[None, :] + 1]
    c = g[iy[:, None] + 1, ix[None, :]]
    d = g[iy[:, None] + 1, ix[None, :] + 1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fbm2d(h, w, base, octs, rng):
    s, a, tot = 0, 1.0, 0
    for o in range(octs):
        kx = base * 2 ** o
        ky = max(1, int(round(kx * h / w)))
        s = s + a * noise2d(h, w, kx, ky, rng)
        tot += a
        a *= .5
    return s / tot


def ridge(w, y0, amp, base, rng, octs=5, sharp=0.0):
    """Mountain-like ridge line: y position per column, y0 minus amp times fractal noise."""
    s, a, tot = 0, 1.0, 0
    for o in range(octs):
        n = noise1d(w, int(base * 2 ** o), rng)
        if sharp:
            n = (1 - sharp) * n + sharp * (1 - np.abs(2 * n - 1))
        s = s + a * n
        tot += a
        a *= .5
    return y0 - amp * s / tot


def stars(img, rng, region_h, n, strength=1.0, mask=None):
    h, w, _ = img.shape
    layer = np.zeros((h, w), np.float32)
    xs = rng.integers(0, w, n)
    ys = (rng.random(n) ** 1.5 * region_h).astype(int)
    layer[ys, xs] = rng.random(n) ** 2.5
    big = np.zeros((h, w), np.float32)
    k = max(1, n // 40)
    big[(rng.random(k) ** 1.5 * region_h).astype(int), rng.integers(0, w, k)] = 1
    layer = np.clip(blur(layer, .75) * 6, 0, 1) + np.clip(blur(big, 1.4) * 10, 0, 1)
    if mask is not None:
        layer = layer * mask
    addl(img, hx("#dfe8ff"), np.clip(layer, 0, 1), .85 * strength)


def finish(img, grain=0.022, vig=0.22, seed=0, bloom=0.0):
    """Bloom, soft highlight roll-off, vignette and film grain, then quantise to 8-bit."""
    h, w, _ = img.shape
    if bloom:
        img = img + blur(np.clip(img - .62, 0, None), 16) * bloom
    img = np.where(img > .8, .8 + .2 * np.tanh((img - .8) / .2), img).astype(np.float32)
    r2 = ((X(w) - w / 2) / (w / 2)) ** 2 + ((Y(h) - h / 2) / (h / 2)) ** 2
    img = img * (1 - vig * np.clip(r2 / 2, 0, 1) ** 1.2)[..., None]
    rng = np.random.default_rng(seed + 991)
    img = img + rng.normal(0, grain, (h, w, 1)).astype(np.float32) + rng.normal(0, grain * .35, (h, w, 3)).astype(np.float32)
    return (np.clip(img, 0, 1) * 255 + .5).astype(np.uint8)


def save(arr, rel):
    path = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    im = Image.fromarray(arr)
    im.save(path, quality=90, subsampling=0, optimize=True)
    MANIFEST.append((rel, im.size))


def scene_glow(img, cx, cy, r, col, a, squash=1.0):
    d = np.hypot(X(img.shape[1]) - cx, (Y(img.shape[0]) - cy) * squash)
    addl(img, hx(col), np.exp(-(d / r) ** 2), a)


def disc(img, cx, cy, r, col, a=1.0):
    d = np.hypot(X(img.shape[1]) - cx, Y(img.shape[0]) - cy)
    over(img, hx(col), np.clip((r - d) + .5, 0, 1), a)


def soft_cloud(img, cx, cy, rx, ry, col, a, soft):
    p = Pen(img.shape[1], img.shape[0], 1)
    p.ellipse(cx, cy, rx, ry)
    over(img, hx(col), p.mask(soft), a)


def mountains_dawn(w, h, seed):
    rng = np.random.default_rng(seed)
    img = vgrad(w, h, [(0, "#171a45"), (.3, "#4a4388"), (.55, "#c9728f"), (.72, "#ffb08f"), (1, "#ffe2b0")])
    sx, sy = w * .63, h * .6
    scene_glow(img, sx, sy, h * .6, "#ff9a70", .55)
    scene_glow(img, sx, sy, h * .13, "#ffe9c0", .6)
    disc(img, sx, sy, h * .045, "#fff3d6")
    stars(img, rng, h * .38, int(w * h / 7000), mask=np.clip(1 - np.hypot(X(w) - sx, Y(h) - sy) / (h * .6), 0, 1))
    haze = hx("#e590a6")
    n = 6
    for i in range(n):
        d = i / (n - 1)
        ry = ridge(w, h * (.56 + .085 * i), h * (.21 + .03 * d), 2 + i * .7, rng, 5, .65 if i < 4 else .35)
        hz = (1 - d) ** 1.25
        dark = mixc(hx("#5b3f86"), hx("#0b0a22"), d)
        top = mixc(dark, haze, hz * .62)
        bot = mixc(top, haze, .55 * (1 - d * .6))
        cov = fill_below(img, ry, top, bot)
        if i < 4:
            edge = cov * np.clip(1 - (Y(h) - ry[None, :]) / 5, 0, 1)
            addl(img, hx("#ffd2a0"), edge, .3 * hz)
    return finish(img, seed=seed, vig=.2, bloom=.25)


def dunes(w, h, seed):
    rng = np.random.default_rng(seed)
    img = vgrad(w, h, [(0, "#2a1d5c"), (.3, "#8a3f86"), (.55, "#e2675f"), (.75, "#ffa85e"), (1, "#ffdc9a")])
    sx, sy = w * .34, h * .46
    scene_glow(img, sx, sy, h * .6, "#ff9a60", .6)
    scene_glow(img, sx, sy, h * .14, "#ffe5b0", .7)
    disc(img, sx, sy, h * .075, "#fff0cc")
    x = np.linspace(0, 1, w, dtype=np.float32)
    n = 5
    hazec = hx("#ffc08a")
    for i in range(n):
        d = i / (n - 1)
        f0 = 1.1 + .45 * i
        th = TAU * (x * f0 * (w / h) * .7 + rng.random())
        v = np.sin(th) + .45 * np.sin(2 * th + 1.1)
        saw = np.clip(v / 1.5 * .5 + .5, 0, 1) ** 1.4
        ry = h * (.58 + .105 * i) - h * (.075 + .06 * d) * (.62 * saw + .38 * noise1d(w, 2 + i, rng))
        slope = blur(np.gradient(ry)[None, :], 6, 0)[0]
        lit = (.5 + .5 * np.tanh(-slope * 2.0))[:, None]
        lit_c = mixc(hx("#ffb27a"), hx("#b04a30"), d)
        sh_c = mixc(hx("#c0597a"), hx("#2f1440"), d)
        hz = (1 - d) * .55
        top = mixc(mixc(sh_c, lit_c, lit), hazec, hz)[None, :, :]
        bot = mixc(mixc(lit_c, sh_c, .55), hx("#1d0f2e"), .3 * d)
        cov = fill_below(img, ry, top, bot)
        edge = cov * np.clip(1 - (Y(h) - ry[None, :]) / 3, 0, 1)
        addl(img, hx("#ffe0b0"), edge, .35 * (1 - d * .5))
    return finish(img, seed=seed, vig=.22, bloom=.3)


def sea_dusk(w, h, seed):
    rng = np.random.default_rng(seed)
    hz = h * .58
    img = sky(w, h, hz, [(0, "#1d1b4a"), (.35, "#6a3a7c"), (.65, "#d9587a"), (.85, "#ff9a5c"), (1, "#ffd08a")])
    sx = w * .58
    scene_glow(img, sx, hz - h * .01, h * .5, "#ff8a5a", .7, 1.2)
    scene_glow(img, sx, hz - h * .01, h * .1, "#fff0c0", .9)
    disc(img, sx, hz - h * .005, h * .05, "#fff4d8")
    for _ in range(7):
        soft_cloud(img, rng.uniform(.05, .95) * w, hz - rng.uniform(.06, .32) * h, rng.uniform(.1, .25) * w,
                   rng.uniform(.008, .02) * h, "#ff8f7a", rng.uniform(.25, .5), h * .008)
    stars(img, rng, h * .25, int(w * h / 14000))
    ry = ridge(w, hz + 2, h * .06, 3, rng, 4, .3)
    ry = ry + np.clip((w * .15 - np.abs(np.arange(w) - w * .84)) * 0, 0, 1)
    mask_isle = np.exp(-((np.arange(w) - w * .86) / (w * .09)) ** 2)
    ry = hz + 2 - (hz + 2 - ry) * mask_isle
    fill_below(img, ry, hx("#3a2058"), hx("#3a2058"), limit=hz)
    ry2 = ridge(w, hz + 2, h * .035, 5, rng, 3, .2) + 0
    fade = np.exp(-((np.arange(w) - w * .1) / (w * .12)) ** 2)
    ry2 = hz + 2 - (hz + 2 - ry2) * fade
    fill_below(img, ry2, hx("#7a4a88"), hx("#7a4a88"), limit=hz)
    sea = vgrad(w, h, [(0, "#000000"), (max(.01, hz / h - .001), "#000000"), (hz / h, "#e0707a"), (hz / h + (1 - hz / h) * .35, "#8a3f7c"), (1, "#1a1a40")])
    d = np.clip((Y(h) - hz) / (h - hz), 0, 1)
    R = rng.standard_normal((h, w)).astype(np.float32)
    R = blur(R, w * .012, 1.4)
    R = R / (R.std() + 1e-6)
    sea = sea * (1 + .16 * R[..., None] * (.3 + d[..., None]))
    wd = w * .012 + d * w * .1
    refl = np.exp(-((X(w) - sx) / wd) ** 2) * np.clip(.5 + .8 * R, 0, 1) * smoothstep(-.4, .8, R) * (1 - .55 * d)
    sea = sea + hx("#ffc9a0") * refl[..., None] * .95
    over(img, sea, np.clip(Y(h) - hz + .5, 0, 1) * np.ones((1, w), np.float32))
    band = np.exp(-((Y(h) - hz) / (h * .012)) ** 2)
    addl(img, hx("#ffd8a8"), band * np.ones((1, w), np.float32), .22)
    return finish(img, seed=seed, vig=.25, bloom=.3)


def aurora_lake(w, h, seed):
    rng = np.random.default_rng(seed)
    hz = h * .64
    img = sky(w, h, hz, [(0, "#040916"), (.5, "#0a1a35"), (1, "#16435a")])
    stars(img, rng, hz * .9, int(w * h / 4500))
    x = np.linspace(0, 1, w, dtype=np.float32)
    aur = np.zeros_like(img)
    yy = Y(h)
    for k, (c0, c1, c2) in enumerate([("#57ffb5", "#22c9a0", "#8a63ff"), ("#8cffd2", "#2fe0b0", "#5b8cff"), ("#45f0a8", "#1aa890", "#c36bff")]):
        yc = h * (.30 + .09 * k) + h * .07 * np.sin(TAU * (x * (1.1 + .5 * k) + rng.random())) + h * .04 * noise1d(w, 4, rng)
        L = h * (.15 + .03 * k)
        above = np.exp(np.minimum(yy - yc[None, :], 0) / L) * (yy < yc[None, :] + 1)
        below = np.exp(-np.maximum(yy - yc[None, :], 0) / (L * .35))
        prof = np.where(yy < yc[None, :], above, below)
        rays = .45 + .55 * noise1d(w, 90 + 20 * k, rng)
        slow = .5 + .8 * noise1d(w, 6, rng)
        t = np.clip((yc[None, :] - yy) / (L * 2.2), 0, 1)
        col = np.where(t[..., None] < .5, mixc(hx(c0), hx(c1), t[..., None] * 2), mixc(hx(c1), hx(c2), (t[..., None] - .5) * 2))
        aur += col * (prof * rays[None, :] * slow[None, :])[..., None]
    aur = aur * (yy < hz)[..., None]
    img += blur(aur, 1.2, 2.5) * .75 + blur(aur, 30) * .45
    for i, (base, amp, col, sh) in enumerate([(hz, h * .14, "#0d2230", .5), (hz, h * .1, "#05101a", .25)]):
        ry = ridge(w, base + 2, amp, 3 + 2 * i, rng, 5, sh)
        fill_below(img, ry, hx(col), hx(col), limit=hz)
    ys = np.arange(h)
    src = np.clip(2 * hz - ys, 0, h - 1).astype(int)
    d = np.clip((Y(h) - hz) / (h - hz), 0, 1)
    R = blur(rng.standard_normal((h, w)).astype(np.float32), 10, 1.2)
    sh = np.sin(Y(h) * .25) * (.5 + 3 * d) + R * 7 * d
    gx = np.clip(X(w) + sh, 0, w - 1).astype(int)
    refl = img[src[:, None], gx]
    refl = blur(refl, 1.5, 2.5) * (.62 - .25 * d[..., None]) + hx("#06141e") * (.25 + .15 * d[..., None])
    refl = refl * (1 + .25 * R[..., None])
    over(img, refl, np.clip(Y(h) - hz + .5, 0, 1) * np.ones((1, w), np.float32))
    return finish(img, seed=seed, vig=.28, bloom=.2)


def pines(p, x, gy, ht):
    tiers = 5
    for k in range(tiers):
        top = gy - ht + k * ht * .16
        th = ht * .3
        hw = ht * .06 + k * ht * .04
        p.poly([(x, top), (x - hw, top + th), (x + hw, top + th)])
    p.rect(x - ht * .012, gy - ht * .1, x + ht * .012, gy + 2)


def forest(w, h, seed):
    rng = np.random.default_rng(seed)
    img = vgrad(w, h, [(0, "#8cb5ae"), (.45, "#d3e3d8"), (1, "#eef0dc")])
    scene_glow(img, w * .72, h * .16, h * .55, "#fff3cc", .6)
    fog = hx("#e2ebdf")
    n = 6
    for i in range(n):
        d = i / (n - 1)
        gy = h * (.5 + .09 * i) if i < n - 1 else h * 1.03
        ht = h * (.2 + .075 * i)
        p = Pen(w, h, 2)
        x = -ht * .2
        while x < w + ht * .2:
            hh = ht * rng.uniform(.65, 1.15)
            pines(p, x, gy + rng.uniform(-.02, .02) * h, hh)
            x += ht * (rng.uniform(.16, .36) if i < 4 else rng.uniform(.1, .22))
        p.rect(0, min(gy, h - 1), w, h)
        m = p.mask()
        dark = mixc(hx("#27504a"), hx("#07171a"), d)
        col = mixc(dark, fog, (1 - d) ** 1.3 * .8)
        tt = np.clip((Y(h) - (gy - ht)) / (ht * 1.1), 0, 1)[..., None]
        over(img, mixc(col, fog, tt * (.6 * (1 - d) + .12)), m)
        band = np.exp(-((Y(h) - (gy - ht * .1)) / (h * .16)) ** 2)
        img[...] = mixc(img, fog, (band * .3 * (1 - d * .6))[..., None] * np.ones((1, w, 1), np.float32))
        if i == 2:
            s = X(w) - Y(h) * .55
            st = (.5 + .5 * np.sin(s / (w * .045) + noise1d(w, 8, rng)[None, :] * 3)) ** 3
            st = blur(st * np.clip(1 - Y(h) / (h * .9), 0, 1), 22)
            addl(img, hx("#fff0c4"), st, .26)
    return finish(img, seed=seed, vig=.2, bloom=.2)


def city_dusk(w, h, seed):
    rng = np.random.default_rng(seed)
    hz = h * .8
    u = w / 1600
    img = sky(w, h, hz, [(0, "#0e0f3a"), (.35, "#43286f"), (.62, "#c4457c"), (.82, "#ff8f6b"), (1, "#ffd58f")])
    scene_glow(img, w * .4, hz, h * .45, "#ff9a6a", .5, 1.5)
    stars(img, rng, h * .3, int(w * h / 9000))
    hazec = hx("#d8658c")
    win = np.zeros((h, w, 3), np.float32)
    wim = Image.new("RGB", (w, h), (0, 0, 0))
    wd = ImageDraw.Draw(wim)
    spec = [(.28, "#7b4a96", .55, .1, (.14, .36)), (.55, "#43275f", .3, .22, (.18, .5)), (1.0, "#150f26", 0, .3, (.1, .5))]
    pal = ["#ffd98a", "#ffc266", "#fff0c0", "#ffb26b", "#a8e6ff"]
    for depth, colr, hzf, prob, (lo, hi) in spec:
        p = Pen(w, h, 2)
        x = -int(20 * u)
        rects = []
        while x < w:
            bw = int(rng.integers(int(40 * u), int(115 * u)))
            bh = h * rng.uniform(lo, hi) * (1.35 if rng.random() < .12 else 1)
            p.rect(x, hz - bh, x + bw, hz + 3)
            rects.append((x, hz - bh, bw, bh))
            if rng.random() < .15 and bh > h * .3:
                p.rect(x + bw / 2 - 1.5 * u, hz - bh - 30 * u, x + bw / 2 + 1.5 * u, hz - bh)
            x += bw + int(rng.integers(0, int(10 * u) + 1))
        over(img, mixc(hx(colr), hazec, hzf * .5), p.mask())
        if hzf > 0:
            pass
        cw, chh = max(4, int(8 * u * (1 + depth))), max(5, int(11 * u * (1 + depth)))
        for (bx, by, bw, bh) in rects:
            gx = cw * 2
            gyy = chh * 2
            yy = int(by + gyy * .6)
            while yy + chh < hz - 4:
                xx = int(bx + gx * .5)
                while xx + cw < bx + bw - gx * .3:
                    if rng.random() < prob * (1.2 if yy > h * .6 else .8):
                        c = pal[int(rng.integers(0, 4))] if rng.random() > .06 else pal[4]
                        k = rng.uniform(.5, 1.0) * (.55 + .45 * depth)
                        cc = tuple(int(v * 255 * k) for v in hx(c))
                        wd.rectangle([xx, yy, xx + cw - 1, yy + chh - 1], fill=cc)
                    xx += gx
                yy += gyy
    win = np.asarray(wim, np.float32) / 255
    img += win * .9 + blur(win, 5) * .9 + blur(win, 18) * .5
    ground = np.clip(Y(h) - hz + .5, 0, 1) * np.ones((1, w), np.float32)
    over(img, mixc(hx("#1a1126"), hx("#07050e"), np.clip((Y(h) - hz) / (h - hz), 0, 1)[..., None]), ground)
    addl(img, hx("#ff9a6a"), np.exp(-((Y(h) - hz - 4 * u) / (6 * u)) ** 2) * np.ones((1, w), np.float32), .18)
    src = np.clip(2 * hz - np.arange(h), 0, h - 1).astype(int)
    d = np.clip((Y(h) - hz) / (h - hz), 0, 1)
    rw = blur(win[src], 2, 6) * (.5 * (1 - d))[..., None]
    rw = blur(rw, 3, 0)
    img += rw * ground[..., None]
    return finish(img, seed=seed, vig=.25, bloom=.25)


def mesh(w, h, seed, stops, cols, n=7, angle=35, rings=2):
    """Smooth mesh-gradient field: a base gradient with big soft colour blobs and thin ring accents."""
    rng = np.random.default_rng(seed)
    img = lgrad(w, h, stops, angle)
    m = max(w, h)
    for i in range(n):
        cx, cy = rng.uniform(-.05, 1.05) * w, rng.uniform(-.05, 1.05) * h
        r = rng.uniform(.22, .5) * m
        d = np.hypot(X(w) - cx, Y(h) - cy)
        over(img, hx(cols[i % len(cols)]), np.exp(-(d / r) ** 2 * 1.6), rng.uniform(.5, .9))
    p = Pen(w, h, 2)
    for _ in range(rings):
        cx, cy, r = rng.uniform(.1, .9) * w, rng.uniform(.1, .9) * h, rng.uniform(.25, .55) * min(w, h)
        p.ring(cx, cy, r, min(w, h) * .004)
    addl(img, hx("#ffffff"), p.mask(.6), .3)
    return img


def banner_mesh(w, h, seed):
    img = mesh(w, h, seed, [(0, "#120d36"), (.5, "#6a2a9a"), (1, "#ff6a8a")], ["#ff9a6a", "#7a5cff", "#ff5c8a", "#3ac6d8", "#ffd08a"], 12, 20, 3)
    return finish(img, seed=seed, vig=.18, bloom=.2)


def banner_bokeh(w, h, seed):
    rng = np.random.default_rng(seed)
    img = lgrad(w, h, [(0, "#0b2a4a"), (.6, "#1a5a7a"), (1, "#f0a070")], 15)
    for _ in range(46):
        cx, cy, r = rng.uniform(0, w), rng.uniform(0, h), rng.uniform(.04, .16) * h
        d = np.hypot(X(w) - cx, Y(h) - cy) / r
        prof = (.35 + .65 * smoothstep(.65, 1.0, d)) * (1 - smoothstep(.97, 1.05, d))
        addl(img, hx(["#ffd9a0", "#ffb3c0", "#bfefff", "#fff2d0"][int(rng.integers(0, 4))]), prof, rng.uniform(.06, .22))
    return finish(img, seed=seed, vig=.2, bloom=.3)


def poster_arches(w, h, seed, pal):
    rng = np.random.default_rng(seed)
    img = vgrad(w, h, [(0, pal["bg"][0]), (1, pal["bg"][1])])
    cx, bottom = w * .5, h * .8
    p = Pen(w, h)
    p.circle(w * .74, h * .13, w * .07)
    paper(img, p.mask(), hx(pal["sun"]), 10, 12, .25)
    p = Pen(w, h)
    p.ring(w * .74, h * .13, w * .105, 3)
    addl(img, hx(pal["sun"]), p.mask(.5), .55)
    for i, wf in enumerate([.74, .58, .42, .26]):
        p = Pen(w, h)
        p.arch(cx - w * wf / 2, h * (.17 + .09 * i), cx + w * wf / 2, bottom + 2)
        col = vgrad(w, h, [(0, pal["arches"][i]), (1, pal["arches"][i])])
        paper(img, p.mask(), mixc(hx(pal["arches"][i]), hx(pal["arches"][i]) * .86, np.clip((Y(h) - h * .2) / (h * .6), 0, 1)[..., None]))
    p = Pen(w, h)
    p.circle(cx, h * .52, w * .035)
    over(img, hx(pal["sun"]), p.mask(), .9)
    for k, (gx, gy, rx, ry, col) in enumerate([(w * .15, h * 1.04, w * .62, h * .2, pal["ground"][0]), (w * .88, h * 1.03, w * .55, h * .17, pal["ground"][1])]):
        p = Pen(w, h)
        p.ellipse(gx, gy, rx, ry)
        paper(img, p.mask(), hx(col), 16, 18, .38)
    p = Pen(w, h)
    for k in range(5):
        p.circle(w * .08 + k * w * .035, h * .06, 5)
    over(img, hx(pal["sun"]), p.mask(), .85)
    return finish(img, seed=seed, vig=.14, grain=.03)


def poster_moon(w, h, seed, pal):
    rng = np.random.default_rng(seed)
    img = vgrad(w, h, [(0, pal["bg"][0]), (.55, pal["bg"][1]), (1, pal["bg"][2])])
    stars(img, rng, h * .5, 260)
    mx, my, mr = w * .5, h * .34, w * .27
    scene_glow(img, mx, my, mr * 1.7, pal["glow"], .45)
    p = Pen(w, h)
    p.circle(mx, my, mr)
    m = p.mask()
    paper(img, m, lgrad(w, h, [(0, pal["moon"][0]), (1, pal["moon"][1])], 65), 0, 30, .0)
    p = Pen(w, h)
    p.circle(mx - mr * .35, my - mr * .2, mr * .18)
    p.circle(mx + mr * .3, my + mr * .35, mr * .12)
    p.circle(mx + mr * .1, my - mr * .5, mr * .07)
    over(img, hx(pal["moon"][1]), p.mask(1), .25)
    p = Pen(w, h)
    p.ring(w * .3, h * .46, w * .2, 4)
    p.ring(w * .7, h * .46, w * .2, 4)
    addl(img, hx(pal["moon"][0]), p.mask(.6), .35)
    x = np.arange(w, dtype=np.float32) / w
    for i in range(7):
        ry = h * (.6 + .055 * i) + h * .02 * np.sin(TAU * (x * (1.2 + .3 * i) + rng.random())) + h * .01 * np.sin(TAU * (x * 3.1 + rng.random()))
        paper(img, cov_below(h, w, ry), hx(pal["waves"][i]), 12, 14, .4)
    return finish(img, seed=seed, vig=.22, grain=.026, bloom=.25)


def poster_sun(w, h, seed, pal):
    rng = np.random.default_rng(seed)
    img = vgrad(w, h, [(0, pal["bg"][0]), (1, pal["bg"][1])])
    cx, cy, r = w * .5, h * .4, w * .27
    scene_glow(img, cx, cy, r * 1.8, pal["glow"], .5)
    p = Pen(w, h)
    p.circle(cx, cy, r)
    for i in range(8):
        y0 = cy + r * (.05 + i * .12)
        p.rect(cx - r - 2, y0, cx + r + 2, y0 + 4 + i * 3.5, 0)
    paper(img, p.mask(), vgrad(w, h, [(0, pal["sunc"][0]), (1, pal["sunc"][1])]), 14, 18, .22)
    x = np.arange(w, dtype=np.float32) / w
    for i in range(5):
        ry = h * (.62 + .07 * i) - h * .06 * np.abs(np.sin(TAU * (.5 + .25 * i) * x + rng.random() * 6)) ** .9 * (1 - .12 * i)
        paper(img, cov_below(h, w, ry), hx(pal["hills"][i]), 14, 18, .35)
    p = Pen(w, h)
    for k in range(3):
        bx, by = w * (.2 + .06 * k), h * (.2 + .02 * (k % 2))
        p.line([(bx - 14, by), (bx, by - 9), (bx + 14, by)], 3)
    over(img, hx(pal["hills"][-1]), p.mask(.5), .8)
    return finish(img, seed=seed, vig=.15, grain=.03)


def poster_blobs(w, h, seed, pal):
    rng = np.random.default_rng(seed)
    img = vgrad(w, h, [(0, pal["bg"][0]), (1, pal["bg"][1])])
    th = np.linspace(0, TAU, 360, endpoint=False)
    specs = [(.3, .3, .3), (.72, .38, .26), (.4, .64, .3), (.74, .76, .24), (.24, .86, .2)]
    for i, (fx, fy, fr) in enumerate(specs):
        r = w * fr * (1 + .16 * np.sin(3 * th + rng.random() * 6) + .09 * np.sin(5 * th + rng.random() * 6) + .05 * np.sin(2 * th + rng.random() * 6))
        pts = [(w * fx + rr * math.cos(t), h * fy + rr * math.sin(t)) for rr, t in zip(r, th)]
        p = Pen(w, h)
        p.poly(pts)
        paper(img, p.mask(), hx(pal["blobs"][i]), 16, 20, .34)
    p = Pen(w, h)
    p.ring(w * .62, h * .2, w * .12, 4)
    p.ring(w * .62, h * .2, w * .075, 3)
    addl(img, hx(pal["line"]), p.mask(.6), .7)
    p = Pen(w, h)
    for a in range(5):
        for b in range(5):
            p.circle(w * .09 + a * 22, h * .88 + b * 22 - 40, 4)
    over(img, hx(pal["line"]), p.mask(), .7)
    return finish(img, seed=seed, vig=.14, grain=.03)


def lighthouse(w, h, seed):
    rng = np.random.default_rng(seed)
    hz = h * .74
    img = sky(w, h, hz, [(0, "#0b1033"), (.35, "#2a2a6e"), (.65, "#8a4a90"), (.85, "#f0907a"), (1, "#ffc890")])
    stars(img, rng, h * .4, 420)
    for _ in range(6):
        soft_cloud(img, rng.uniform(.0, 1) * w, hz - rng.uniform(.05, .3) * h, rng.uniform(.15, .35) * w, rng.uniform(.008, .016) * h, "#e8809a", rng.uniform(.2, .45), h * .008)
    lx, ly = w * .5, h * .335
    scene_glow(img, lx, ly, h * .3, "#ffd88a", .4)
    scene_glow(img, lx, ly, h * .07, "#fff2c0", .8)
    xx = X(w)
    for sgn in (-1, 1):
        p = Pen(w, h, 1)
        p.poly([(lx, ly), (lx + sgn * w * 1.1, ly - h * .06), (lx + sgn * w * 1.1, ly + h * .08)])
        beam = p.mask(14) * np.exp(-np.abs(xx - lx) / (w * .5))
        addl(img, hx("#ffeab0"), beam, .5)
    sea = vgrad(w, h, [(0, "#000000"), (hz / h - .001, "#000000"), (hz / h, "#d77a86"), (hz / h + .1, "#4a3a7e"), (1, "#0a0d2a")])
    over(img, sea, np.clip(Y(h) - hz + .5, 0, 1) * np.ones((1, w), np.float32))
    d = np.clip((Y(h) - hz) / (h - hz), 0, 1)
    R = blur(rng.standard_normal((h, w)).astype(np.float32), w * .01, 1.5)
    R /= R.std() + 1e-6
    refl = np.exp(-((X(w) - lx) / (w * .02 + d * w * .1)) ** 2) * smoothstep(-.3, .9, R) * (1 - .5 * d) * (Y(h) > hz)
    addl(img, hx("#ffd890"), refl, .55)
    xn = np.arange(w, dtype=np.float32) / w
    for i in range(5):
        ry = hz + h * (.035 + .045 * i) + h * .008 * np.sin(TAU * (xn * (6 + 2 * i) + rng.random()))
        cov = cov_below(h, w, ry)
        col = mixc(hx("#2e2a68"), hx("#06082a"), i / 4)
        over(img, col, cov, .92)
        addl(img, hx("#d8c8ff"), cov * np.clip(1 - (Y(h) - ry[None, :]) / 3, 0, 1), .1 + .04 * i)
    rk = ridge(w, h * .93, h * .09, 3, rng, 5, .5) - h * .08 * np.exp(-((np.arange(w) - w * .5) / (w * .17)) ** 2)
    fill_below(img, rk, hx("#241a30"), hx("#08060e"))
    ytop, ybot = h * .365, h * .8
    tw0, tw1 = w * .045, w * .075
    p = Pen(w, h)
    p.poly([(lx - tw0, ytop), (lx + tw0, ytop), (lx + tw1, ybot), (lx - tw1, ybot)])
    tower = p.mask()
    yy = Y(h)
    frac = np.clip((yy - ytop) / (ybot - ytop), 0, 1)
    half = tw0 + (tw1 - tw0) * frac
    xn2 = np.clip((X(w) - lx) / half, -1, 1)
    band = (np.floor((yy - ytop) / ((ybot - ytop) / 6)).astype(int) % 2)[..., None]
    base = np.where(band == 0, hx("#e8d8c8"), hx("#c8505a")) * np.ones((1, w, 1), np.float32)
    shade = (.35 + .65 * (1 - (xn2 + 1) / 2) ** .8)[..., None]
    over(img, base * shade * (.8 + .2 * frac[..., None]), tower)
    addl(img, hx("#ffd8a0"), tower * np.clip(-xn2, 0, 1) ** 2, .0)
    p = Pen(w, h)
    p.rect(lx - tw0 * 1.5, ytop - h * .006, lx + tw0 * 1.5, ytop + h * .008)
    p.rect(lx - tw0 * 1.5, ytop - h * .026, lx - tw0 * 1.5 + 4, ytop)
    p.rect(lx + tw0 * 1.5 - 4, ytop - h * .026, lx + tw0 * 1.5, ytop)
    over(img, hx("#1a1424"), p.mask())
    p = Pen(w, h)
    p.rect(lx - tw0 * .95, ytop - h * .05, lx + tw0 * .95, ytop - h * .006)
    over(img, hx("#fff0b8"), p.mask())
    addl(img, hx("#ffffff"), p.mask(), .35)
    p = Pen(w, h)
    p.poly([(lx - tw0 * 1.2, ytop - h * .05), (lx + tw0 * 1.2, ytop - h * .05), (lx, ytop - h * .095)])
    p.circle(lx, ytop - h * .1, w * .007)
    over(img, hx("#1a1424"), p.mask())
    p = Pen(w, h)
    p.rect(lx - 3, ytop - h * .05, lx + 3, ytop - h * .006)
    over(img, hx("#7a5a30"), p.mask(), .8)
    return finish(img, seed=seed, vig=.28, bloom=.3)


def waterfall(w, h, seed):
    rng = np.random.default_rng(seed)
    img = vgrad(w, h, [(0, "#a7d3cf"), (.45, "#e4efe0"), (1, "#f4f2dc")])
    scene_glow(img, w * .5, h * .12, h * .4, "#fffbe0", .5)
    cx = w * .5
    yy = Y(h)
    ys = np.arange(h, dtype=np.float32)
    pool_y = h * .76
    halfw = w * (.06 + .05 * np.clip((ys - h * .24) / (pool_y - h * .24), 0, 1) ** 1.5)
    n = 3
    for layer in range(n):
        d = layer / (n - 1)
        off = w * (.07 - .03 * d)
        nx = noise1d(h, 6 + 2 * layer, rng)
        xl = np.minimum(cx - halfw - off + (nx - .5) * w * .07, cx - halfw - 4)
        nx2 = noise1d(h, 7 + 2 * layer, rng)
        xr = np.maximum(cx + halfw + off + (nx2 - .5) * w * .07, cx + halfw + 4)
        topl = h * (.17 + .05 * layer) + noise1d(w, 8, rng)[None, :1] * 0
        tl = h * (.14 + .04 * layer) + h * .03 * noise1d(w, 7 + layer, rng)
        cl = np.clip(xl[:, None] - X(w) + .5, 0, 1) * np.clip(yy - tl[None, :] + .5, 0, 1) * (1 if layer else 1)
        cr = np.clip(X(w) - xr[:, None] + .5, 0, 1) * np.clip(yy - tl[::-1][None, :] + .5, 0, 1)
        m = np.clip(cl + cr, 0, 1)
        dark = mixc(hx("#6f8a86"), hx("#27403a"), d ** .8)
        tex = .75 + .6 * blur(rng.random((h, w)).astype(np.float32), 1.2, 16) + .25 * (noise2d(h, w, 3, 14, rng) - .5)
        shade = .65 + .5 * np.clip(1 - np.abs(X(w) - cx) / (w * .5), 0, 1) ** 1.5
        col = mixc(dark, hx("#e4efe0"), (1 - d) * .45)
        over(img, col * (tex * shade)[..., None], m)
        topfringe = m * np.clip(1 - (yy - tl[None, :]) / (h * .035 * (1 + noise1d(w, 20, rng)[None, :])), 0, 1)
        over(img, mixc(hx("#3d7a54"), hx("#12331f"), d), topfringe, .95)
        fogband = np.exp(-((yy - h * .55) / (h * .25)) ** 2)
        img[...] = mixc(img, hx("#e8f1e4"), (fogband * .22 * (1 - d))[..., None] * np.ones((1, w, 1), np.float32))
    S = blur(rng.standard_normal((h, w)).astype(np.float32), 1.3, 34)
    S = S / (S.std() + 1e-6)
    wm = np.clip((halfw[:, None] - np.abs(X(w) - cx) + 4) / 8, 0, 1) * np.clip((yy - h * .24) / 6, 0, 1) * np.clip((pool_y - yy) / 14, 0, 1)
    wc = mixc(hx("#a8d4dc"), hx("#ffffff"), np.clip(.5 + .55 * S, 0, 1)[..., None])
    over(img, wc, wm, .96)
    edge = np.clip(1 - np.abs(np.abs(X(w) - cx) - halfw[:, None]) / 10, 0, 1) * wm
    over(img, hx("#7aa8b0"), edge, .3)
    pool = vgrad(w, h, [(0, "#000000"), (pool_y / h - .001, "#000000"), (pool_y / h, "#4aa8a4"), (1, "#0d3d48")])
    R = blur(rng.standard_normal((h, w)).astype(np.float32), w * .01, 2)
    R /= R.std() + 1e-6
    pool = pool * (1 + .12 * R[..., None])
    pm = np.clip(yy - pool_y + .5, 0, 1) * np.ones((1, w), np.float32)
    over(img, pool, pm)
    for _ in range(14):
        soft_cloud(img, cx + rng.normal(0, w * .06), pool_y + rng.normal(0, h * .02), rng.uniform(.06, .14) * w, rng.uniform(.015, .04) * h, "#ffffff", rng.uniform(.3, .6), h * .02)
    soft_cloud(img, cx, pool_y - h * .02, w * .25, h * .05, "#ffffff", .35, h * .03)
    p = Pen(w, h)
    for sx_, sy_, rr in [(.0, 1.0, .3), (1.0, 1.02, .28), (.2, 1.05, .2), (.85, 1.0, .22)]:
        pts = []
        for t in np.linspace(0, TAU, 80, endpoint=False):
            r_ = w * rr * (1 + .12 * math.sin(3 * t + sx_ * 5) + .06 * math.sin(7 * t))
            pts.append((w * sx_ + r_ * math.cos(t), h * sy_ + r_ * .55 * math.sin(t)))
        p.poly(pts)
    over(img, mixc(hx("#1d2a2a"), hx("#07100f"), np.clip((yy - h * .85) / (h * .15), 0, 1)[..., None]), p.mask(1.2))
    return finish(img, seed=seed, vig=.22, bloom=.2)


def sq_mesh(w, h, seed):
    img = mesh(w, h, seed, [(0, "#14123a"), (.5, "#6a2f8f"), (1, "#ff7a5c")], ["#ffb36b", "#6a5cff", "#ff4f8a", "#3ad0c0", "#ffe0a0"], 9, 55, 3)
    return finish(img, seed=seed, vig=.2, bloom=.2)


def sq_arcs(w, h, seed):
    img = vgrad(w, h, [(0, "#f6e8d2"), (1, "#ecd2b4")])
    cx, cy = w / 2, h * .74
    cols = ["#d9553f", "#f0a24e", "#f4d27a", "#7fb08a", "#2f7a8a", "#233f5e"]
    for i, c in enumerate(cols):
        p = Pen(w, h)
        r = w * (.46 - .07 * i)
        p.pie(cx, cy, r, 180, 360)
        paper(img, p.mask(), hx(c), 8, 12, .3)
    p = Pen(w, h)
    p.circle(w * .5, h * .16, w * .06)
    paper(img, p.mask(), hx("#d9553f"), 8, 10, .25)
    p = Pen(w, h)
    p.rect(0, cy, w, h)
    paper(img, p.mask(), hx("#233f5e"), -6, 10, .3)
    return finish(img, seed=seed, vig=.1, grain=.03)


def sq_tiles(w, h, seed):
    rng = np.random.default_rng(seed)
    pal = ["#e4572e", "#f3a712", "#29335c", "#a8c686", "#669bbc", "#f0e4d0"]
    img = np.zeros((h, w, 3), np.float32)
    t = w // 3
    for gy in range(3):
        for gx in range(3):
            bgc, fg = rng.choice(len(pal), 2, replace=False)
            x0, y0 = gx * t, gy * t
            p = Pen(w, h)
            p.rect(x0, y0, x0 + t, y0 + t)
            over(img, hx(pal[bgc]), p.mask())
            kind = int(rng.integers(0, 5))
            p = Pen(w, h)
            if kind == 0:
                p.circle(x0 + t / 2, y0 + t / 2, t * .32)
            elif kind == 1:
                p.pie(x0, y0 + t, t * .9, 270, 360)
            elif kind == 2:
                p.pie(x0 + t / 2, y0 + t / 2, t * .38, 0, 180)
            elif kind == 3:
                p.circle(x0 + t / 2, y0 + t / 2, t * .38)
                p.circle(x0 + t / 2, y0 + t / 2, t * .2, 0)
            else:
                p.rect(x0 + t * .12, y0 + t * .12, x0 + t * .88, y0 + t * .88)
                p.circle(x0 + t / 2, y0 + t / 2, t * .26, 0)
            clip = Pen(w, h)
            clip.rect(x0, y0, x0 + t, y0 + t)
            over(img, hx(pal[fg]), p.mask() * clip.mask())
    return finish(img, seed=seed, vig=.08, grain=.03)


def card(w, h, seed, stops, cols, angle):
    img = mesh(w, h, seed, stops, cols, 6, angle, 0)
    p = Pen(w, h)
    p.circle(w * .78, h * .3, h * .55)
    p.circle(w * .78, h * .3, h * .42, 0)
    addl(img, hx("#ffffff"), p.mask(1.5), .16)
    p = Pen(w, h)
    p.circle(w * .15, h * .85, h * .4)
    addl(img, hx("#ffffff"), p.mask(40), .12)
    return finish(img, seed=seed, vig=.18, bloom=.2)


AV_PALETTES = [
    ("#ff9a8b", "#ff6a88", "#6a3093", "#fff4e6", "#2b1b4d", "#ffd56b"),
    ("#43cea2", "#2a9d8f", "#185a9d", "#f2fff9", "#0b2f4a", "#ffe08a"),
    ("#f6d365", "#fda085", "#f093fb", "#fffaf0", "#5b2a86", "#2d1b4e"),
    ("#0f2027", "#203a43", "#2c5364", "#e8fbff", "#7fe0d0", "#ffb36b"),
    ("#fbc2eb", "#a18cd1", "#667eea", "#ffffff", "#2d2a6e", "#ffd1e8"),
    ("#ffecd2", "#fcb69f", "#e76f51", "#fff8ef", "#264653", "#2a9d8f"),
    ("#1e3c72", "#2a5298", "#6dd5ed", "#ffffff", "#0f1f4a", "#ffd166"),
    ("#141e30", "#243b55", "#4b6cb7", "#f5e6c8", "#e0a458", "#ffffff"),
    ("#c471f5", "#fa71cd", "#ffa8a8", "#ffffff", "#4a1d6b", "#ffe3f1"),
    ("#96e6a1", "#6dd47e", "#1b8a5a", "#f4fff0", "#0f4d36", "#fff3a8"),
    ("#ff512f", "#f09819", "#ffcf6b", "#fff7e8", "#7a1f1f", "#3b0f0f"),
    ("#2b5876", "#4e4376", "#a26fa4", "#fdf3ff", "#ffc971", "#2b2160"),
    ("#00c6fb", "#2fa7e8", "#005bea", "#ffffff", "#08285e", "#bdf3ff"),
    ("#f857a6", "#ff5858", "#ffb199", "#fff6f0", "#5a1030", "#ffe08a"),
    ("#a8edea", "#8fd3f4", "#84a9ff", "#ffffff", "#26356b", "#fff0b8"),
    ("#3a1c71", "#d76d77", "#ffaf7b", "#fff4e0", "#2a0f4a", "#ffe0a0"),
]


def motif_layers(kind, S):
    """Return a list of (mask, colour index, alpha) layers for one avatar motif; colour 0 light, 1 accent, 2 accent2."""
    c = S / 2
    L = []

    def P():
        return Pen(S, S, 3)

    if kind == 0:
        p = P()
        p.circle(c, c, 84)
        q = P()
        q.ring(c, c, 120, 9)
        L += [(q.mask(), 0, .4), (p.mask(), 0, 1)]
    elif kind == 1:
        p = P()
        p.circle(c, c + 30, 90)
        p.rect(0, c + 30, S, S, 0)
        b1 = P()
        b1.rrect(100, 242, 300, 254, 6)
        b2 = P()
        b2.rrect(135, 268, 265, 278, 5)
        L += [(p.mask(), 0, 1), (b1.mask(), 0, .7), (b2.mask(), 0, .4)]
    elif kind == 2:
        for r, ci in [(104, 0), (78, 1), (54, 0), (30, 2)]:
            p = P()
            p.circle(c, c, r)
            L.append((p.mask(), ci, 1))
    elif kind == 3:
        p = P()
        p.arch(138, 104, 262, 306)
        q = P()
        q.arch(166, 150, 234, 306)
        L += [(p.mask(), 0, 1), (q.mask(), 1, 1)]
    elif kind == 4:
        p = P()
        p.poly([(96, 292), (190, 128), (284, 292)])
        q = P()
        q.poly([(190, 292), (268, 190), (346, 292)])
        s = P()
        s.circle(284, 118, 24)
        L += [(s.mask(), 2, 1), (p.mask(), 0, 1), (q.mask(), 1, 1)]
    elif kind == 5:
        yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
        circ = P()
        circ.circle(c, c, 100)
        stripes = np.clip(((np.sin((xx + yy) / 13.0) + .25) * 6), 0, 1)
        L += [(circ.mask() * stripes, 0, 1)]
    elif kind == 6:
        p = P()
        p.circle(c, c, 92)
        p.circle(c + 34, c - 18, 78, 0)
        s = P()
        s.circle(290, 120, 7)
        L += [(p.mask(), 0, 1), (s.mask(), 2, 1)]
    elif kind == 7:
        for k in range(3):
            a = math.radians(90 + 120 * k)
            p = P()
            p.circle(c + 46 * math.cos(a), c + 46 * math.sin(a), 62)
            L.append((p.mask(), [0, 1, 2][k], .72))
    elif kind == 8:
        yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
        win = np.clip((100 - np.abs(xx - c)) / 6, 0, 1)
        for k in range(3):
            d = yy - (c - 52 + k * 52 + 20 * np.sin(xx / 28.0 + k))
            L.append((np.clip((13 - np.abs(d)), 0, 1) * win, [0, 2, 0][k], 1))
    elif kind == 9:
        p = P()
        p.poly([(c, 92), (c + 108, c), (c, S - 92), (c - 108, c)])
        q = P()
        q.poly([(c, 142), (c + 58, c), (c, S - 142), (c - 58, c)])
        L += [(p.mask(), 0, 1), (q.mask(), 1, 1)]
    elif kind == 10:
        for gy in range(3):
            for gx in range(3):
                p = P()
                p.circle(c + (gx - 1) * 66, c + (gy - 1) * 66, 21)
                L.append((p.mask(), 1 if (gx, gy) == (1, 1) else 0, 1 if (gx, gy) != (1, 1) else 1))
    elif kind == 11:
        for k, (ox, oy, a0) in enumerate([(c, c, 180), (c, c, 270), (c, c, 0), (c, c, 90)]):
            p = P()
            p.pie(c + (-1 if a0 in (180, 90) else 1) * 4, c + (-1 if a0 in (180, 270) else 1) * 4, 82, a0, a0 + 90)
            L.append((p.mask(), [0, 1, 2, 0][k], 1))
    elif kind == 12:
        a = P()
        a.circle(160, c, 72)
        b = P()
        b.circle(240, c, 72)
        L += [(a.mask(), 0, .85), (b.mask(), 1, .85), (a.mask() * b.mask(), 2, 1)]
    elif kind == 13:
        yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
        p = P()
        p.circle(c, c, 96)
        m = p.mask()
        left = np.clip((c - xx) / 1.5 + .5, 0, 1)
        L += [(m * left, 0, 1), (m * (1 - left), 1, 1)]
    elif kind == 14:
        for k, (wd_, ci) in enumerate([(190, 0), (136, 1), (92, 2)]):
            p = P()
            p.rrect(c - 95, 118 + k * 56, c - 95 + wd_, 118 + k * 56 + 38, 19)
            L.append((p.mask(), ci, 1))
    else:
        p = P()
        p.ring(c, c, 100, 16)
        q = P()
        q.circle(c + 22, c - 22, 38)
        L += [(p.mask(), 0, 1), (q.mask(), 1, 1)]
    return L


def avatar(i):
    S = 400
    b0, b1, b2, light, acc, acc2 = AV_PALETTES[i]
    angle = [40, 125, 70, 110, 55, 145, 35, 100, 120, 60, 80, 135, 50, 115, 90, 30][i]
    img = lgrad(S, S, [(0, b0), (.5, b1), (1, b2)], angle)
    scene_glow(img, S * .3, S * .22, S * .55, "#ffffff", .18)
    cols = [hx(light), hx(acc), hx(acc2)]
    for m, ci, a in motif_layers(i, S):
        sh = blur(shift(m, 0, 7), 8)
        img *= (1 - sh * .26 * a)[..., None]
        over(img, cols[ci], m, a)
    return finish(img, seed=i, grain=.018, vig=.1)


FONT_PATHS = ["/usr/share/fonts/TTF/DejaVuSansMono.ttf", "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
              "/usr/share/fonts/liberation/LiberationMono-Regular.ttf", "/usr/share/fonts/noto/NotoSansMono-Regular.ttf"]


def mono(size):
    for p in FONT_PATHS:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


CODE = """use std::collections::HashMap;
use crate::frame::{Frame, Pixels};

const TILE: usize = 16;
const GAMMA: f32 = 2.2;

/// Renders a single frame into a pixel buffer.
pub struct Renderer<'a> {
    frame: &'a Frame,
    cache: HashMap<u32, Pixels>,
    scale: f32,
}

impl<'a> Renderer<'a> {
    pub fn new(frame: &'a Frame, scale: f32) -> Self {
        Self { frame, cache: HashMap::new(), scale }
    }

    pub fn render(&mut self, frame: &Frame) -> Pixels {
        let mut out = Pixels::with_capacity(frame.len());
        for (i, tile) in frame.tiles(TILE).enumerate() {
            let key = tile.hash() ^ i as u32;
            if let Some(hit) = self.cache.get(&key) {
                out.extend_from(hit);
                continue;
            }
            let shaded = tile.map(|px| px.powf(1.0 / GAMMA) * self.scale);
            self.cache.insert(key, shaded.clone());
            out.extend_from(&shaded);
        }
        out
    }
}
"""
CODE = CODE.strip()

KEYWORDS = set("use const pub struct impl fn let mut for in if else while loop match return self Self as where mod enum trait type unsafe move ref continue break true false".split())
TOK = re.compile(r"(//.*$)|(\"(?:[^\"\\]|\\.)*\")|('[a-z]\b)|(\b\d[\d_.]*[a-z0-9]*\b)|(\b[A-Za-z_]\w*!)|(\b[A-Za-z_]\w*)(?=\()|(\b[A-Z]\w*\b)|(\b[a-z_]\w*\b)|(\s+)|(.)")


def highlight(line):
    """Split a Rust-like line into (text, colour) tokens in a One-Dark-like theme."""
    out = []
    for m in TOK.finditer(line):
        g = m.lastindex
        t = m.group(0)
        if g == 1:
            c = "#5c6370"
        elif g == 2:
            c = "#98c379"
        elif g == 3:
            c = "#e5c07b"
        elif g == 4:
            c = "#d19a66"
        elif g == 5:
            c = "#e06c75"
        elif g == 6:
            c = "#61afef"
        elif g == 7:
            c = "#e5c07b"
        elif g == 8:
            c = "#c678dd" if t in KEYWORDS else "#e06c75" if t in ("self",) else "#abb2bf"
        else:
            c = "#56b6c2" if t in "&|?" else "#abb2bf"
        out.append((t, c))
    return out


def window_chrome(d, w, bar, title=None, font=None):
    d.rectangle([0, 0, w, 40], fill=bar)
    for i, c in enumerate(["#ff5f56", "#ffbd2e", "#27c93f"]):
        d.ellipse([18 + i * 24, 14, 30 + i * 24, 26], fill=c)
    if title:
        tw = d.textlength(title, font=font)
        d.text((w / 2 - tw / 2, 11), title, font=font, fill="#7f848e")


def shot_editor(seed):
    W, H = 1400, 900
    im = Image.new("RGB", (W, H), "#282c34")
    d = ImageDraw.Draw(im)
    f, fs = mono(17), mono(13)
    window_chrome(d, W, "#21252b", "renderer.rs", mono(14))
    d.rectangle([0, 40, 250, H], fill="#21252b")
    d.text((18, 56), "EXPLORER", font=fs, fill="#7f848e")
    tree = [(0, "dir", "src"), (1, "rs", "main.rs"), (1, "rs", "frame.rs"), (1, "sel", "renderer.rs"), (1, "rs", "tiles.rs"), (1, "rs", "cache.rs"),
            (0, "dir", "tests"), (1, "rs", "smoke.rs"), (0, "dir", "assets"), (1, "toml", "Cargo.toml"), (1, "md", "README.md")]
    y = 84
    for ind, kind, name in tree:
        x = 18 + ind * 18
        if kind == "sel":
            d.rectangle([0, y - 4, 250, y + 22], fill="#2c313a")
        if kind == "dir":
            d.polygon([(x, y + 5), (x + 9, y + 5), (x + 4.5, y + 12)], fill="#7f848e")
            d.text((x + 16, y), name, font=f, fill="#abb2bf")
        else:
            col = {"rs": "#e5c07b", "sel": "#e5c07b", "toml": "#61afef", "md": "#98c379"}[kind]
            d.rounded_rectangle([x + 4, y + 3, x + 14, y + 15], radius=2, fill=col)
            d.text((x + 22, y), name, font=f, fill="#e6e9ef" if kind == "sel" else "#abb2bf")
        y += 28
    d.rectangle([250, 40, W, 80], fill="#21252b")
    d.rectangle([250, 40, 470, 80], fill="#282c34")
    d.rectangle([250, 40, 470, 42], fill="#61afef")
    d.text((272, 50), "renderer.rs", font=f, fill="#e6e9ef")
    d.text((492, 50), "frame.rs", font=f, fill="#7f848e")
    lines = CODE.split("\n")
    lh = 23
    cw = f.getlength("M")
    y0 = 92
    d.rectangle([250, y0 + 12 * lh - 3, W - 90, y0 + 12 * lh + lh - 3], fill="#2c313a")
    for i, ln in enumerate(lines):
        y = y0 + i * lh
        d.text((262, y), str(i + 1).rjust(2), font=f, fill="#e6e9ef" if i == 12 else "#4b5263")
        x = 320
        for t, c in highlight(ln):
            d.text((x, y), t, font=f, fill=c)
            x += cw * len(t)
        ind = len(ln) - len(ln.lstrip())
        for k in range(0, ind, 4):
            if ln.strip():
                d.line([(320 + k * cw, y - 1), (320 + k * cw, y + lh - 2)], fill="#3b4048")
    d.rectangle([W - 90, 80, W, H - 28], fill="#262a32")
    for i, ln in enumerate(lines):
        x = W - 80
        for t, c in highlight(ln):
            if t.strip() and x < W - 6:
                d.rectangle([x, 96 + i * 5, min(x + len(t) * 1.7, W - 6), 98 + i * 5], fill=c)
            x += len(t) * 1.7
    d.rectangle([0, H - 28, W, H], fill="#3b82f6")
    d.text((16, H - 23), "main    0 errors    0 warnings", font=fs, fill="#ffffff")
    d.text((W - 380, H - 23), "Ln 13, Col 30    Spaces: 4    UTF-8    Rust", font=fs, fill="#ffffff")
    return np.asarray(im)


def shot_terminal(seed):
    W, H = 1400, 900
    im = Image.new("RGB", (W, H), "#1a1b26")
    d = ImageDraw.Draw(im)
    f = mono(17)
    window_chrome(d, W, "#16161e", "zsh  -  120x36", mono(14))
    cw = f.getlength("M")
    G, B, Yc, R, C, M, T, DIM = "#9ece6a", "#7aa2f7", "#e0af68", "#f7768e", "#7dcfff", "#bb9af7", "#c0caf5", "#565f89"
    rows = [
        [("~/dev/frames", B), (" on ", DIM), ("main", M), (" via ", DIM), ("rust 1.84", Yc)],
        [("> ", G), ("cargo build --release", T)],
        [("   Compiling ", G), ("tiles v0.4.1", T)],
        [("   Compiling ", G), ("frame v0.9.0", T)],
        [("   Compiling ", G), ("renderer v0.2.3", T)],
        [("warning", Yc), (": unused variable: ", T), ("`scale`", C)],
        [("  --> ", B), ("src/renderer.rs:41:13", T)],
        [("   |", B)],
        [("41 |", B), ("     let scale = 1.0;", T)],
        [("   |", B), ("         ^^^^^ ", Yc), ("help: prefix with an underscore", T)],
        [("    Finished ", G), ("`release` profile [optimized] target(s) in 12.4s", T)],
        [],
        [("~/dev/frames", B), (" on ", DIM), ("main", M), (" took ", DIM), ("12s", Yc)],
        [("> ", G), ("cargo test", T)],
        [("running 14 tests", T)],
        [("test cache::evicts_oldest ... ", T), ("ok", G)],
        [("test cache::hits_on_same_key ... ", T), ("ok", G)],
        [("test frame::empty_is_zero_sized ... ", T), ("ok", G)],
        [("test renderer::renders_empty_frame ... ", T), ("ok", G)],
        [("test tiles::splits_evenly ... ", T), ("ok", G)],
        [("test tiles::handles_remainder ... ", T), ("FAILED", R)],
        [("failures:", R)],
        [("    tiles::handles_remainder", T)],
        [("test result: ", T), ("FAILED", R), (". 13 passed; 1 failed; 0 ignored", T)],
        [("~/dev/frames", B), (" on ", DIM), ("main", M), (" took ", DIM), ("2s", Yc)],
        [("> ", G), ("git diff --stat", T)],
        [(" src/tiles.rs    ", T), ("|  6 ", DIM), ("++++", G), ("--", R)],
        [(" src/renderer.rs |  3 ", T), ("++", G), ("-", R)],
        [(" 2 files changed, 7 insertions(+), 2 deletions(-)", T)],
        [],
        [("~/dev/frames", B), (" on ", DIM), ("main", M), (" ", DIM)],
    ]
    y = 62
    for r in rows:
        x = 34
        for t, c in r:
            d.text((x, y), t, font=f, fill=c)
            x += cw * len(t)
        y += 24
    d.text((34, y), "> ", font=f, fill=G)
    d.rectangle([34 + cw * 2, y + 2, 34 + cw * 3, y + 21], fill="#c0caf5")
    d.rectangle([0, H - 30, W, H], fill="#16161e")
    d.text((16, H - 24), "[0] zsh   1 editor   2 logs", font=mono(13), fill=DIM)
    d.text((W - 200, H - 24), "frames   14:32", font=mono(13), fill=DIM)
    return np.asarray(im)


def lowres_to_frame(arr, W, H, rng, grain=.008):
    chans = [np.asarray(Image.fromarray(np.ascontiguousarray(arr[..., c], dtype=np.float32), "F").resize((W, H), Image.BICUBIC)) for c in range(3)]
    full = np.stack(chans, -1)
    full = full + rng.standard_normal((H, W, 1), dtype=np.float32) * grain + rng.standard_normal((H, W, 3), dtype=np.float32) * grain * .3
    return (np.clip(full, 0, 1) * 255 + .5).astype(np.uint8)


def encode(rel, W, H, frame_fn, count=180, fps=30, seed=0):
    path = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(fps), "-i", "-",
           "-c:v", "libx264", "-preset", "medium", "-crf", "21", "-pix_fmt", "yuv420p", "-movflags", "+faststart", path]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    rng = np.random.default_rng(seed)
    for i in range(count):
        fr = frame_fn(TAU * i / count)
        if i == 0:
            Image.fromarray(fr).save(path[:-4] + ".jpg", quality=90, subsampling=0)
            MANIFEST.append((rel[:-4] + ".jpg", (W, H)))
        proc.stdin.write(fr.tobytes())
    proc.stdin.close()
    if proc.wait() != 0:
        sys.exit("ffmpeg failed for " + rel)
    MANIFEST.append((rel, (W, H)))


def video_silk(W, H, stops, seed, lw=216):
    lh = int(round(lw * H / W))
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:lh, 0:lw].astype(np.float32)
    u, v = xx / lw * 1.9, yy / lw * 1.9
    vig = 1 - .35 * np.clip(((xx / lw - .5) ** 2 + (yy / lh - .5) ** 2) * 2, 0, 1)

    def frame(th):
        a = np.sin(u * 1.3 + 1.1 * np.sin(v * 1.1 + th) + th)
        b = np.sin(v * 1.6 + 1.3 * np.sin(u * .9 - th) + 1.7)
        c = np.sin((u + v) * .9 + 1.4 * np.sin(u * 1.4 + v * .7 + 2 * th))
        f = np.clip(.5 + .3 * a + .2 * b + .14 * c, 0, 1)
        f = f * f * (3 - 2 * f) * .8 + f * .2
        col = ramp(f, stops)
        gy, gx = np.gradient(blur(f, 1.5))
        light = np.clip(-(gx * .7 + gy * 1.0) * 45, -1, 1)
        col = col + light[..., None] * .13
        col = col * vig[..., None]
        return lowres_to_frame(col, W, H, rng)

    return frame


def video_aurora(W, H, seed, lw=216):
    lh = int(round(lw * H / W))
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:lh, 0:lw].astype(np.float32)
    x, y = xx / lw, yy / lh
    hz = lh * .74
    base = sky(lw, lh, hz, [(0, "#030812"), (.55, "#0a1d3a"), (1, "#14465c")])
    st = np.zeros((lh, lw), np.float32)
    sx = rng.integers(0, lw, 110)
    sy = (rng.random(110) ** 1.3 * hz * .8).astype(int)
    st[sy, sx] = rng.random(110)
    phs = rng.random((lh, lw)).astype(np.float32) * TAU
    hill = ridge(lw, hz + 1, lh * .09, 3, rng, 4, .35)
    hill2 = ridge(lw, hz + 1, lh * .05, 6, rng, 4, .2)
    cov1, cov2 = cov_below(lh, lw, hill) * (yy < hz), cov_below(lh, lw, hill2) * (yy < hz)
    src = np.clip(2 * hz - np.arange(lh), 0, lh - 1).astype(int)
    dd = np.clip((Y(lh) - hz) / (lh - hz), 0, 1)
    lake = (yy >= hz).astype(np.float32)
    rcols = [("#57ffb5", "#22c9a0", "#8a63ff"), ("#8cffd2", "#2fe0b0", "#5b8cff"), ("#45f0a8", "#1aa890", "#c36bff")]
    nz = noise1d(lw, 7, rng)

    def frame(th):
        img = base.copy()
        tw = .55 + .45 * np.sin(th * 2 + phs)
        img += hx("#dfe8ff") * (st * tw)[..., None] * .9
        aur = np.zeros_like(img)
        for k, (c0, c1, c2) in enumerate(rcols):
            yc = (.34 + .07 * k) + .05 * np.sin(TAU * x * (1.0 + .4 * k) + th + k) + .025 * np.sin(TAU * x * 3 - 2 * th + k * 2)
            L = .15 + .02 * k
            d = y - yc
            prof = np.where(d < 0, np.exp(d / L), np.exp(-d / (L * .3)))
            rays = .55 + .25 * np.sin(x * 120 + 3 * np.sin(x * 9 + th + k) + 2 * th * (k % 2 + 1) + k) + .2 * np.sin(x * 47 - th + k * 3)
            slow = .7 + .3 * np.sin(x * 11 - th + k * 1.7) + .15 * np.sin(x * 5 + 2 * th)
            t = np.clip(-d / (L * 2.2), 0, 1)[..., None]
            col = np.where(t < .5, mixc(hx(c0), hx(c1), t * 2), mixc(hx(c1), hx(c2), (t - .5) * 2))
            aur += col * (prof * rays * slow)[..., None] * .8
        aur = aur * (yy < hz)[..., None]
        img += blur(aur, .8, 1.5) * .8 + blur(aur, 8) * .4
        over(img, hx("#0a1822"), cov1)
        over(img, hx("#050d14"), cov2)
        refl = blur(img[src], 1.2, 2.5) * (.5 - .25 * dd[..., None]) + hx("#06141e") * .3
        over(img, refl, lake)
        return lowres_to_frame(np.clip(img, 0, 1.2) * (1 - .2 * ((x - .5) ** 2 + (y - .5) ** 2) * 2)[..., None], W, H, rng)

    return frame


def video_bokeh(W, H, seed, lw=360):
    lh = int(round(lw * H / W))
    rng = np.random.default_rng(seed)
    bg = vgrad(lw, lh, [(0, "#0a2a4a"), (.45, "#1c6a86"), (.8, "#8a6a8e"), (1, "#f2a46e")])
    N = 38
    cx = rng.uniform(0, lw, N)
    y0 = rng.uniform(0, 1, N)
    rad = rng.uniform(.025, .1, N) * lw * rng.choice([.7, 1, 1.4], N)
    cyc = rng.choice([1, 1, 2], N)
    sway = rng.uniform(2, 14, N)
    ph = rng.uniform(0, TAU, N)
    amp = rng.uniform(.08, .26, N)
    pal = [hx(c) for c in ["#ffd9a0", "#ffb3c0", "#bfefff", "#fff2d0", "#ffc88a"]]
    pick = rng.integers(0, 5, N)
    span = lh + 2 * rad.max()

    def frame(th):
        img = bg.copy()
        g1 = np.hypot(X(lw) - (lw * .3 + 40 * np.sin(th)), Y(lh) - (lh * .75 + 30 * np.cos(th)))
        addl(img, hx("#ff9a7a"), np.exp(-(g1 / (lw * .6)) ** 2), .25)
        g2 = np.hypot(X(lw) - (lw * .75 + 30 * np.cos(th)), Y(lh) - (lh * .25 + 40 * np.sin(th)))
        addl(img, hx("#5ad0e0"), np.exp(-(g2 / (lw * .5)) ** 2), .2)
        for i in range(N):
            t = th / TAU
            yv = (y0[i] * span - span * t * cyc[i]) % span - rad.max()
            xv = cx[i] + sway[i] * np.sin(th * cyc[i] + ph[i])
            r = rad[i]
            xa, xb, ya, yb = int(max(0, xv - r - 2)), int(min(lw, xv + r + 3)), int(max(0, yv - r - 2)), int(min(lh, yv + r + 3))
            if xb <= xa or yb <= ya:
                continue
            d = np.hypot(X(lw)[:, xa:xb] - xv, Y(lh)[ya:yb] - yv) / r
            prof = (.3 + .7 * smoothstep(.62, 1.0, d)) * (1 - smoothstep(.96, 1.05, d))
            a = amp[i] * (.75 + .25 * np.sin(th + ph[i]))
            img[ya:yb, xa:xb] += pal[pick[i]] * (prof * a)[..., None]
        return lowres_to_frame(img * (1 - .25 * (((X(lw) / lw - .5) ** 2 + (Y(lh) / lh - .5) ** 2) * 2))[..., None], W, H, rng)

    return frame


def video_sea(W, H, seed, lw=640):
    lh = int(round(lw * H / W))
    rng = np.random.default_rng(seed)
    hz = lh * .56
    base = sky(lw, lh, hz, [(0, "#191c4a"), (.35, "#5a3d8a"), (.65, "#e0607e"), (.85, "#ffa86a"), (1, "#ffe0a8")])
    x, y = X(lw) / lw, Y(lh)
    yn = y / lh
    sx = .56
    d = np.clip((y - hz) / (lh - hz), 0, 1)
    seabase = vgrad(lw, lh, [(0, "#000000"), (hz / lh - .001, "#000000"), (hz / lh, "#d8707a"), (hz / lh + .3, "#7a3a76"), (1, "#181a3e")])
    sea_cov = np.clip(y - hz + .5, 0, 1) * np.ones((1, lw), np.float32)
    rp = [rng.random((lh, 1)).astype(np.float32) * TAU for _ in range(3)]
    persp = 1 / (.06 + d)
    isl = ridge(lw, hz + 1, lh * .05, 3, np.random.default_rng(5), 4, .3)
    isl = hz + 1 - (hz + 1 - isl) * np.exp(-((np.arange(lw) / lw - .87) / .1) ** 2)

    def frame(th):
        img = base.copy()
        cl = .5 + .3 * np.sin(x * 4.5 + 1.0 * np.sin(yn * 9 + th) + th) + .2 * np.sin(x * 9 - 2 * th + yn * 14)
        band = np.exp(-((y - hz * .6) / (lh * .2)) ** 2) * (y < hz)
        cm = smoothstep(.62, .95, cl) * band * (.6 + .4 * np.sin(yn * 70 + x * 3 + th))
        addl(img, hx("#ff9d86"), cm, .4)
        scene_glow(img, lw * sx, hz - 4, lh * .5, "#ff8a5a", .55, 1.2)
        scene_glow(img, lw * sx, hz - 4, lh * .11, "#fff0c0", .8)
        disc(img, lw * sx, hz - 2, lh * .055, "#fff4d8")
        w1 = np.sin(x * persp * 7 + th * 2 + rp[0])
        w2 = np.sin(x * persp * 13 - th * 3 + rp[1])
        w3 = np.sin(x * persp * 4 + th + rp[2])
        wave = .5 + .5 * (.45 * w1 + .35 * w2 + .35 * w3) / 1.15
        sea = seabase * (1 + .3 * (wave[..., None] - .5) * (.3 + d[..., None]))
        wd = .012 + d * .1
        refl = np.exp(-((x - sx) / wd) ** 2) * smoothstep(.35, .85, wave) * (1 - .5 * d)
        sea = sea + hx("#ffc9a0") * refl[..., None] * .95
        over(img, sea, sea_cov)
        addl(img, hx("#ffd8a8"), np.exp(-((y - hz) / 2.5) ** 2) * np.ones((1, lw), np.float32), .2)
        fill_below(img, isl, hx("#3a2058"), hx("#3a2058"), limit=hz)
        return lowres_to_frame(img * (1 - .22 * (((x - .5) ** 2 + (yn - .5) ** 2) * 2))[..., None], W, H, rng)

    return frame


def write_manifest():
    rels = sorted(MANIFEST)
    with open(os.path.join(OUT, "MANIFEST.txt"), "w") as fh:
        for rel, (w, h) in rels:
            fh.write(f"{rel}  {w}x{h}\n")


def main():
    t0 = time.time()
    os.makedirs(OUT, exist_ok=True)
    only = sys.argv[1:]

    def want(name):
        return not only or any(o in name for o in only)

    def step(name, fn):
        if want(name):
            t = time.time()
            fn()
            print(f"{name:12s} {time.time() - t:6.1f}s", flush=True)

    step("avatars", lambda: [save(avatar(i), f"avatars/a{i + 1:02d}.jpg") for i in range(16)])
    banners = [mountains_dawn, aurora_lake, dunes, banner_mesh, sea_dusk, city_dusk]
    step("banners", lambda: [save(fn(1500, 500, 11 + i), f"banners/b{i + 1:02d}.jpg") for i, fn in enumerate(banners)])
    lands = [mountains_dawn, dunes, sea_dusk, aurora_lake, forest, city_dusk]
    step("land", lambda: [save(fn(1600, 1067, 31 + i), f"photos/land_{i + 1:02d}.jpg") for i, fn in enumerate(lands)])
    pal_a = {"bg": ["#f5e6d0", "#e9c9a6"], "arches": ["#c8553d", "#e8a35c", "#7a9e7e", "#2d4a53"], "sun": "#f8f0e0", "ground": ["#8a5a44", "#3a2a2f"]}
    pal_m = {"bg": ["#0c1030", "#2b2a6e", "#6a3a86"], "glow": "#ffcf8a", "moon": ["#fff3d0", "#f2b07a"], "waves": ["#4a3a8e", "#3d3480", "#312a70", "#262060", "#1c1850", "#141040", "#0b0a2e"]}
    pal_s = {"bg": ["#ffe3d0", "#f6b8b0"], "glow": "#ffe0b0", "sunc": ["#ffd56b", "#ff6a7a"], "hills": ["#c8587a", "#9a3f7a", "#6a2f7a", "#432468", "#241a4a"]}
    pal_b = {"bg": ["#e8eddc", "#cfdcc4"], "blobs": ["#5f8f6e", "#e3a65a", "#2f5a5a", "#d9694a", "#f2d9a0"], "line": "#27463f"}
    step("port", lambda: [save(poster_arches(1200, 1600, 41, pal_a), "photos/port_01.jpg"), save(poster_moon(1200, 1600, 42, pal_m), "photos/port_02.jpg"),
                          save(poster_sun(1200, 1600, 43, pal_s), "photos/port_03.jpg"), save(lighthouse(1200, 1600, 44), "photos/port_04.jpg"),
                          save(waterfall(1200, 1600, 45), "photos/port_05.jpg"), save(poster_blobs(1200, 1600, 46, pal_b), "photos/port_06.jpg")])
    step("sq", lambda: [save(sq_mesh(1080, 1080, 51), "photos/sq_01.jpg"), save(sq_arcs(1080, 1080, 52), "photos/sq_02.jpg"), save(sq_tiles(1080, 1080, 53), "photos/sq_03.jpg")])
    step("shot", lambda: [save(shot_editor(1), "photos/shot_01.jpg"), save(shot_terminal(2), "photos/shot_02.jpg")])
    step("card", lambda: [save(card(1200, 628, 61, [(0, "#2a1560"), (.5, "#8a3a9a"), (1, "#ff7a6a")], ["#ffb36b", "#6a5cff", "#ff5c8a", "#3ac6d8"], 25), "photos/card_01.jpg"),
                          save(card(1200, 628, 62, [(0, "#0b3a48"), (.5, "#2a8a7a"), (1, "#f0e0b0")], ["#a8e6c0", "#2a6aa0", "#ffd890", "#58c0b0"], 150), "photos/card_02.jpg")])
    step("v_port_01", lambda: encode("videos/v_port_01.mp4", 720, 1280, video_silk(720, 1280, [(0, "#24104a"), (.3, "#6a2a8e"), (.55, "#f0457e"), (.8, "#ff9a5a"), (1, "#ffe0a8")], 1), seed=1))
    step("v_port_02", lambda: encode("videos/v_port_02.mp4", 720, 1280, video_aurora(720, 1280, 2), seed=2))
    step("v_port_03", lambda: encode("videos/v_port_03.mp4", 720, 1280, video_bokeh(720, 1280, 3), seed=3))
    step("v_land_01", lambda: encode("videos/v_land_01.mp4", 1280, 720, video_sea(1280, 720, 4), seed=4))
    write_manifest()
    print(f"total {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
