"""The release video's score, synthesized: a loud, dissonant opening that steps down with every post the
filter hides, a D-major pad that takes over and changes chord with each scene, and small sounds on the
cues release.html exports (clicks, hides, keys, the logo chime)."""
import pathlib

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, fftconvolve, sosfilt

SR = 48000
PITCH = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}

CHORDS = {
    "calm": ["D2", "A2", "F#3", "C#4", "E4"],
    "held": ["B1", "F#2", "D3", "A3", "C#4"],
    "why": ["G1", "D2", "B2", "F#3", "A3"],
    "call": ["E2", "B2", "D3", "F#3", "G3"],
    "strict": ["F#2", "D3", "A3", "C#4", "E4"],
    "model": ["G2", "D3", "F#3", "B3", "C#4"],
    "install": ["A1", "E2", "A2", "D3", "E3"],
    "resolve": ["A1", "E2", "A2", "C#3", "E3"],
    "end": ["D2", "A2", "F#3", "C#4", "E4"],
}
SPARKLE = {
    "calm": ["F#5", "A5", "C#6", "E5"],
    "held": ["B4", "D5", "F#5", "C#6"],
    "why": ["B4", "D5", "F#5", "A5"],
    "call": ["E5", "G5", "B5", "F#5"],
    "strict": ["D5", "F#5", "A5", "E5"],
    "model": ["B4", "D5", "F#5", "C#6"],
    "install": ["A4", "D5", "E5", "A5"],
    "end": ["D5", "F#5", "A5", "E5"],
}


def hz(name: str) -> float:
    midi = 12 * (int(name[-1]) + 1) + PITCH[name[:-1]]
    return 440.0 * 2 ** ((midi - 69) / 12)


def ramp(n: int, rise: int, fall: int) -> np.ndarray:
    """A raised-cosine fade in over `rise` samples and out over the last `fall`."""
    e = np.ones(n)
    rise = max(1, min(rise, n))
    fall = max(1, min(fall, n))
    e[:rise] *= 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, rise))
    e[n - fall :] *= 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, fall))
    return e


def wavetable(harmonics: int, tilt: float, size: int = 4096) -> np.ndarray:
    ph = np.arange(size) / size
    w = sum(np.sin(2 * np.pi * k * ph) / k**tilt for k in range(1, harmonics + 1))
    return w / np.abs(w).max()


WARM = wavetable(18, 1.45)
BUZZ = wavetable(40, 1.0)


def osc(table: np.ndarray, freq, n: int, phase: float = 0.0) -> np.ndarray:
    inc = np.broadcast_to(np.asarray(freq, dtype=float) / SR, (n,))
    ph = (phase + np.cumsum(inc)) % 1.0
    idx = ph * len(table)
    i0 = idx.astype(np.int64)
    frac = idx - i0
    return table[i0 % len(table)] * (1 - frac) + table[(i0 + 1) % len(table)] * frac


class Mix:
    def __init__(self, seconds: float):
        self.n = int(seconds * SR) + SR
        self.dry = np.zeros((2, self.n))
        self.wet = np.zeros((2, self.n))
        self.pad = np.zeros((2, self.n))

    def add_pad(self, t: float, sig: np.ndarray, gain: float):
        start = max(0, int(round(t * SR)))
        end = min(self.n, start + sig.shape[1])
        self.pad[:, start:end] += sig[:, : end - start] * gain

    def add(self, t: float, sig: np.ndarray, gain: float = 1.0, pan: float = 0.0, send: float = 0.0):
        if sig.ndim == 1:
            left = np.cos((pan + 1) * np.pi / 4)
            right = np.sin((pan + 1) * np.pi / 4)
            sig = np.vstack([sig * left, sig * right]) * np.sqrt(2)
        start = int(round(t * SR))
        if start >= self.n:
            return
        if start < 0:
            sig = sig[:, -start:]
            start = 0
        end = min(self.n, start + sig.shape[1])
        self.dry[:, start:end] += sig[:, : end - start] * gain
        if send:
            self.wet[:, start:end] += sig[:, : end - start] * gain * send


def pad(notes, start: float, stop: float, attack: float = 1.1, release: float = 1.6, level: float = 1.0) -> tuple[float, np.ndarray]:
    """Two detuned warm voices per note, panned apart, breathing slowly."""
    n = int((stop - start + release) * SR)
    t = np.arange(n) / SR
    out = np.zeros((2, n))
    for j, name in enumerate(notes):
        f = hz(name)
        weight = 1.0 if f < 120 else 0.8 if f < 300 else 0.62
        for side, cents in ((0, -6.0), (1, 6.5)):
            drift = 1 + 0.0012 * np.sin(2 * np.pi * (0.13 + 0.03 * j) * t + side * 1.7 + j)
            voice = osc(WARM, f * 2 ** (cents / 1200) * drift, n, phase=(0.37 * j + 0.5 * side) % 1)
            out[side] += voice * weight * 0.7
            out[1 - side] += voice * weight * 0.3
    breathe = 1 + 0.08 * np.sin(2 * np.pi * 0.11 * t)
    env = ramp(n, int(attack * SR), int(release * SR))
    return start, out * env * breathe * level / len(notes)


def sub(root: str, start: float, stop: float, level: float = 1.0) -> tuple[float, np.ndarray]:
    f = hz(root)
    while f < 55:
        f *= 2
    n = int((stop - start + 1.4) * SR)
    s = np.sin(2 * np.pi * f * np.arange(n) / SR)
    return start, s * ramp(n, int(0.9 * SR), int(1.4 * SR)) * level


def pluck(freq: float, seconds: float = 1.1, bright: float = 0.35) -> np.ndarray:
    n = int(seconds * SR)
    t = np.arange(n) / SR
    tone = np.sin(2 * np.pi * freq * t) + bright * np.sin(4 * np.pi * freq * t) * np.exp(-t * 9) + 0.12 * np.sin(6 * np.pi * freq * t) * np.exp(-t * 14)
    return tone * np.exp(-t * 4.2) * ramp(n, int(0.004 * SR), int(0.05 * SR))


def bell(freq: float, seconds: float = 3.2) -> np.ndarray:
    n = int(seconds * SR)
    t = np.arange(n) / SR
    partials = [(1.0, 1.0, 1.1), (2.0, 0.55, 1.6), (2.76, 0.32, 2.4), (4.07, 0.18, 3.4), (5.43, 0.1, 4.6)]
    tone = sum(a * np.sin(2 * np.pi * freq * r * t) * np.exp(-t * d) for r, a, d in partials)
    return tone * ramp(n, int(0.003 * SR), int(0.3 * SR)) / 2.1


def boom(seconds: float = 1.3) -> np.ndarray:
    n = int(seconds * SR)
    t = np.arange(n) / SR
    f = 55 + 60 * np.exp(-t * 22)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 3.4) * ramp(n, int(0.004 * SR), int(0.2 * SR))


def click(seed: int, tone: float = 3200, body: float = 170, strength: float = 1.0, seconds: float = 0.03) -> np.ndarray:
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    t = np.arange(n) / SR
    snap = rng.standard_normal(n) * np.exp(-t / 0.0012)
    snap = sosfilt(butter(2, [tone * 0.6, min(tone * 1.8, 20000)], "bandpass", fs=SR, output="sos"), snap)
    thump = np.sin(2 * np.pi * body * t) * np.exp(-t / 0.006) * 0.5
    return (snap * 1.4 + thump) * strength * ramp(n, 8, int(0.01 * SR))


def blip(f0: float, f1: float, seconds: float, decay: float) -> np.ndarray:
    n = int(seconds * SR)
    t = np.arange(n) / SR
    f = f1 + (f0 - f1) * np.exp(-t * (1 / max(decay, 1e-3)))
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 7) * ramp(n, int(0.003 * SR), int(0.04 * SR))


def noise_sweep(seed: int, seconds: float, lo: float, hi: float, rise: float = 0.5) -> np.ndarray:
    """Filtered noise whose band glides from lo to hi and back, as a whoosh."""
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    x = rng.standard_normal(n)
    t = np.arange(n) / n
    shape = np.where(t < rise, t / rise, 1 - (t - rise) / (1 - rise))
    center = lo * (hi / lo) ** np.clip(shape, 0, 1)
    out = np.zeros(n)
    low = band = 0.0
    q = 0.9
    fc = 2 * np.sin(np.pi * center / SR)
    for i in range(n):
        f = fc[i]
        low += f * band
        high = x[i] - low - q * band
        band += f * high
        out[i] = band
    return out * ramp(n, int(n * rise * 0.9), int(n * (1 - rise) * 0.9)) * 0.35


def crowd(seconds: float) -> np.ndarray:
    rng = np.random.default_rng(3)
    n = int(seconds * SR)
    t = np.arange(n) / SR
    hiss = np.asarray(sosfilt(butter(2, [240, 2400], "bandpass", fs=SR, output="sos"), rng.standard_normal(n)))
    chatter = 0.55 + 0.45 * (0.45 * np.sin(2 * np.pi * 3.1 * t + 1) + 0.35 * np.sin(2 * np.pi * 5.3 * t + 2) + 0.2 * np.sin(2 * np.pi * 8.9 * t))
    freqs = [hz("A2"), hz("A#2"), hz("E3"), hz("F3"), hz("B3")]
    buzz = sum(osc(BUZZ, f * (1 + 0.004 * np.sin(2 * np.pi * (5 + i) * t)), n, phase=0.21 * i) for i, f in enumerate(freqs)) / len(freqs)
    buzz = np.asarray(sosfilt(butter(2, 1500, "lowpass", fs=SR, output="sos"), buzz)) * (0.75 + 0.25 * np.sin(2 * np.pi * 11.5 * t))
    return hiss * chatter * 0.55 + buzz * 0.9


def smooth_step(t: np.ndarray, a: float, b: float) -> np.ndarray:
    p = np.clip((t - a) / (b - a), 0, 1)
    return p * p * (3 - 2 * p)


def reverb(seconds: float = 2.6, predelay: float = 0.024) -> np.ndarray:
    rng = np.random.default_rng(11)
    n = int(seconds * SR)
    t = np.arange(n) / SR
    tail = rng.standard_normal((2, n)) * np.exp(-6.9 * t / seconds)
    tail = sosfilt(butter(2, [180, 5200], "bandpass", fs=SR, output="sos"), tail, axis=1)
    ir = np.concatenate([np.zeros((2, int(predelay * SR))), tail], axis=1)
    return ir / np.sqrt((ir**2).sum() / 2)


def render(cues, scenes, duration: float, path) -> None:
    mix = Mix(duration)
    total = mix.n
    t_all = np.arange(total) / SR

    hook_hides = sorted(c["t"] for c in cues if c["kind"] == "hide" and c["t"] < scenes["title"])
    first = hook_hides[0] if hook_hides else 1.5
    loud = np.ones(total)
    for h in hook_hides:
        loud -= smooth_step(t_all, h - 0.06, h + 0.34) / len(hook_hides)
    loud = np.clip(loud, 0, 1) ** 1.3
    noise_len = int((scenes["title"] + 0.2) * SR)
    noisy = crowd(noise_len / SR) * loud[:noise_len] * ramp(noise_len, int(0.02 * SR), int(0.1 * SR))
    mix.add(0, noisy, gain=0.62, send=0.1)

    order = ["held", "why", "call", "strict", "model", "install", "end"]
    starts = [("calm", first - 0.25)] + [(k, scenes[k]) for k in order]
    install_mid = scenes["install"] + (scenes["end"] - scenes["install"]) * 0.55
    for i, (key, start) in enumerate(starts):
        stop = starts[i + 1][1] if i + 1 < len(starts) else duration - 0.6
        if key == "install":
            for part, a, b in (("install", start, install_mid), ("resolve", install_mid, stop)):
                at, sig = pad(CHORDS[part], a - 0.15, b + 0.1, attack=0.7, release=1.3)
                mix.add_pad(at, sig, 0.32)
        else:
            attack = 1.4 if key == "calm" else 0.9
            release = 2.4 if key == "end" else 1.5
            at, sig = pad(CHORDS[key], start - 0.2, stop + 0.1, attack=attack, release=release)
            mix.add_pad(at, sig, 0.32)
        at, sig = sub(CHORDS[key][0], start - 0.1, stop)
        mix.add(at, sig, gain=0.075)

    rng = np.random.default_rng(21)
    sparkle_from = scenes["title"] + 1.3
    for i, (key, start) in enumerate(starts):
        stop = starts[i + 1][1] if i + 1 < len(starts) else duration - 1.4
        t = max(start, sparkle_from) + 0.2
        k = 0
        while t < stop - 0.2:
            note = SPARKLE[key][k % len(SPARKLE[key])]
            mix.add(t, pluck(hz(note), 1.3, 0.25), gain=0.05 + 0.03 * rng.random(), pan=rng.uniform(-0.55, 0.55), send=0.6)
            t += rng.uniform(0.42, 0.78)
            k += 1 + int(rng.random() < 0.35)

    arpeggio = ["D5", "F#5", "A5", "D6", "F#6"]
    later = ["A5", "C#6", "E6"]
    hide_count = 0
    later_count = 0
    for c in cues:
        t = c["t"]
        kind = c["kind"]
        if kind == "hide":
            if t < scenes["title"]:
                note = arpeggio[min(hide_count, len(arpeggio) - 1)]
                hide_count += 1
            else:
                note = later[later_count % len(later)]
                later_count += 1
            mix.add(t, pluck(hz(note), 1.2, 0.45), gain=0.2, pan=0.15, send=0.35)
            mix.add(t + 0.1, blip(260, 120, 0.25, 0.08), gain=0.1)
        elif kind == "scan":
            mix.add(t, noise_sweep(5, 1.1, 400, 3400, 0.7), gain=0.13, pan=0.2, send=0.3)
            mix.add(t, blip(1760, 1760, 0.6, 1.0), gain=0.045, pan=0.55, send=0.6)
        elif kind == "arrive":
            mix.add(t, click(int(t * 1000), tone=5200, body=900, strength=0.35), gain=0.3, pan=-0.1)
        elif kind == "keep":
            mix.add(t, blip(880, 1320, 0.18, 0.03), gain=0.05, send=0.3)
        elif kind in ("click", "rclick"):
            mix.add(t, click(int(t * 997), tone=3000 if kind == "click" else 2600), gain=0.26, pan=0.1)
        elif kind == "toggle":
            mix.add(t, click(77, tone=4200, body=260, strength=0.6), gain=0.24)
            mix.add(t + 0.03, blip(700, 1050, 0.12, 0.02), gain=0.035, send=0.2)
        elif kind == "menu":
            mix.add(t, blip(620, 880, 0.08, 0.02), gain=0.035)
        elif kind == "whoosh":
            mix.add(t - 0.12, noise_sweep(int(t * 31), 0.62, 200, 1900, 0.45), gain=0.3, send=0.25)
        elif kind == "chime":
            mix.add(t, bell(hz("D5")), gain=0.3, pan=-0.12, send=0.5)
            mix.add(t + 0.07, bell(hz("A5"), 2.6), gain=0.16, pan=0.18, send=0.5)
            mix.add(t, boom(), gain=0.38)
        elif kind == "chime-end":
            mix.add(t, bell(hz("D5"), 4.0), gain=0.3, pan=-0.12, send=0.55)
            mix.add(t + 0.09, bell(hz("F#5"), 3.4), gain=0.14, pan=0.12, send=0.55)
            mix.add(t + 0.18, bell(hz("A5"), 3.2), gain=0.12, pan=0.24, send=0.55)
            mix.add(t, boom(1.6), gain=0.32)
        elif kind == "bar":
            mix.add(t, blip(330, 660, 0.7, 0.25), gain=0.03, send=0.3)
        elif kind == "key":
            mix.add(t, click(int(t * 1543), tone=2400 + 900 * ((int(t * 1543) % 7) / 7), body=210, strength=0.5), gain=0.14, pan=-0.05)
        elif kind == "enter":
            mix.add(t, click(int(t * 911), tone=1900, body=150, strength=0.9), gain=0.2)
        elif kind == "tick":
            mix.add(t, pluck(hz("E6"), 0.35, 0.1), gain=0.05, pan=0.2, send=0.25)

    pads = np.asarray(sosfilt(butter(2, 2100, "lowpass", fs=SR, output="sos"), mix.pad, axis=1))
    wet = fftconvolve(mix.wet + pads * 0.32, reverb(), axes=1)[:, :total]
    out = mix.dry + pads + wet * 0.3
    out = np.asarray(sosfilt(butter(2, 32, "highpass", fs=SR, output="sos"), out, axis=1))
    out = np.tanh(out * 1.1) / 1.1
    n = int(duration * SR)
    out = out[:, :n] * ramp(n, int(0.004 * SR), int(1.3 * SR))
    peak = np.abs(out).max()
    out *= 10 ** (-1.0 / 20) / peak
    rms = 20 * np.log10(np.sqrt((out**2).mean()) + 1e-12)
    print(f"score: peak -1.0 dBFS, rms {rms:.1f} dBFS, {n / SR:.2f} s")
    wavfile.write(str(pathlib.Path(path)), SR, (out.T * 32767).astype(np.int16))
