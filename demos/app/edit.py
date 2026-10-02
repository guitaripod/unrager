"""The cut of the iPhone app's marketing video, in beats of the song.

Everything `compose.py` draws is described here: which recording plays where,
the captions over it, the palette behind it and the flashes and rings on the
drops. Times are song beats, not seconds, so the picture lands on the music
whatever its tempo; `beat_time` in `compose.py` turns them into seconds.

Song: Avicii, "Waiting for Love". The edit starts 73.51 s in, the first drop
lands on beat 36 and the second on beat 68.
"""

from __future__ import annotations

from dataclasses import dataclass

WIDTH, HEIGHT, FPS = 1080, 1350, 60
SONG = "/mnt/nvme8tb/Music/Avicii-Avicii_Forever-PROPER-24BIT-WEB-FLAC-2025-TVRf/05-avicii-waiting_for_love-proper.flac"
SONG_START = 73.51
BEAT_ZERO = 0.004
BEAT_SECONDS = 0.4685
LAST_BEAT = 108
DURATION = BEAT_ZERO + BEAT_SECONDS * LAST_BEAT
FADE_OUT = 3.0
CLIPS_DIR = "/mnt/nvme8tb/unrager-demo/clips"
ICON = "/home/marcus/Dev/rust/unrager/ios/Unrager/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
TEXT_WIDTH = 940
RING_CENTER = (WIDTH // 2, 800)
GLOW_GAIN = 0.5
SCRIM_HEIGHT = 340
SCRIM_STRENGTH = 0.7

WHITE = (255, 255, 255, 255)
SKY = (125, 205, 255, 255)
SUN = (255, 208, 110, 255)
ROSE = (255, 140, 170, 255)


@dataclass(frozen=True)
class Glow:
    """A soft coloured light in the background, in fractions of the canvas."""
    x: float
    y: float
    radius: float
    strength: float
    color: tuple[float, ...]
    sway: float = 0.05
    speed: float = 0.5


@dataclass(frozen=True)
class Palette:
    top: tuple[float, ...]
    bottom: tuple[float, ...]
    glows: tuple[Glow, ...]


@dataclass(frozen=True)
class Section:
    beat: float
    palette: Palette


@dataclass(frozen=True)
class Layout:
    """Where a phone rests: its centre, its height in canvas pixels and its tilt."""
    cx: float
    cy: float
    height: float
    tilt: float = 0.0
    decode_scale: float = 1.0


@dataclass(frozen=True)
class Move:
    """A glide of a shot's phone to `layout` between two beats."""
    beat_in: float
    beat_out: float
    layout: Layout


@dataclass(frozen=True)
class Shot:
    """A framed recording shown on a phone from `beat_in` to `beat_out`.

    `src` is the second of the clip playing at `beat_in`, and `speed` how much
    faster than real time it runs.
    """
    scene: str
    beat_in: float
    beat_out: float
    src: float
    layout: Layout
    enter: str = "rise"
    exit: str = "fade"
    pulse: bool = False
    speed: float = 1.0
    moves: tuple[Move, ...] = ()

    @property
    def decode_height(self) -> float:
        """The tallest this shot's phone gets, which is what its clip is decoded at."""
        layouts = [self.layout] + [move.layout for move in self.moves]
        return max(layout.height * layout.decode_scale for layout in layouts)


@dataclass(frozen=True)
class Caption:
    """Text on screen from `beat_in` to `beat_out`, centred at height `y`.

    `*word*` in the text draws that word in the accent colour; `\\n` breaks a line.
    """
    text: str
    beat_in: float
    beat_out: float
    y: float = 105
    size: int = 66
    weight: str = "Bold"
    color: tuple[int, int, int, int] = WHITE
    accent: tuple[int, int, int, int] = SKY
    plate: int = 0


@dataclass(frozen=True)
class AppIcon:
    beat_in: float
    cx: float
    cy: float
    size: float


def blend_palettes(a: Palette, b: Palette, x: float) -> Palette:
    """The palette `x` of the way from `a` to `b`."""
    def mix(p: tuple[float, ...], q: tuple[float, ...]) -> tuple[float, ...]:
        return tuple(u + (v - u) * x for u, v in zip(p, q))

    glows = tuple(
        Glow(*mix((ga.x, ga.y, ga.radius, ga.strength), (gb.x, gb.y, gb.radius, gb.strength)),
             color=mix(ga.color, gb.color), sway=ga.sway, speed=ga.speed)
        for ga, gb in zip(a.glows, b.glows))
    return Palette(mix(a.top, b.top), mix(a.bottom, b.bottom), glows)


CALM = Palette(
    top=(7, 11, 26), bottom=(13, 20, 44),
    glows=(Glow(0.18, 0.30, 0.34, 0.50, (60, 130, 240)),
           Glow(0.86, 0.78, 0.38, 0.42, (24, 190, 170), 0.06, 0.4),
           Glow(0.55, 0.05, 0.28, 0.30, (140, 100, 250), 0.04, 0.3)))
LIFT = Palette(
    top=(10, 8, 34), bottom=(22, 10, 52),
    glows=(Glow(0.15, 0.25, 0.36, 0.70, (120, 90, 255)),
           Glow(0.88, 0.62, 0.38, 0.60, (0, 190, 255), 0.07, 0.6),
           Glow(0.45, 0.95, 0.34, 0.55, (255, 80, 160), 0.06, 0.5)))
BLAZE = Palette(
    top=(26, 8, 30), bottom=(42, 12, 36),
    glows=(Glow(0.12, 0.30, 0.36, 0.80, (255, 120, 60), 0.08, 0.7),
           Glow(0.90, 0.55, 0.38, 0.70, (255, 60, 130), 0.07, 0.6),
           Glow(0.50, 0.92, 0.36, 0.65, (130, 80, 255), 0.06, 0.5)))
DUSK = Palette(
    top=(8, 12, 30), bottom=(14, 24, 50),
    glows=(Glow(0.20, 0.35, 0.36, 0.55, (70, 140, 250)),
           Glow(0.85, 0.70, 0.40, 0.50, (30, 200, 180), 0.06, 0.4),
           Glow(0.50, 0.10, 0.30, 0.35, (150, 110, 255), 0.04, 0.3)))

SECTIONS = [Section(0, CALM), Section(36, LIFT), Section(68, BLAZE), Section(98, DUSK)]

HERO = Layout(540, 830, 1200)
HERO_LEFT = Layout(560, 840, 1190, -2.5)
HERO_RIGHT = Layout(520, 840, 1190, 2.5)
TRIPLE_LEFT = Layout(205, 960, 980, -7)
TRIPLE_MID = Layout(540, 880, 1160)
TRIPLE_RIGHT = Layout(875, 960, 980, 7)


def zoomed(height: float, focus: tuple[float, float], at: tuple[float, float] = (540, 820)) -> Layout:
    """A layout that enlarges the phone to `height` with the point `focus` (0 to 1
    across and down the phone) centred on `at`, so a part of the screen fills the canvas."""
    width = height * 1380 / 2880
    return Layout(at[0] - (focus[0] - 0.5) * width, at[1] - (focus[1] - 0.5) * height, height)


STRIP_ZOOM = zoomed(2150, (0.5, 0.59), at=(540, 860))
NORA_ZOOM = zoomed(2150, (0.5, 0.69), at=(540, 860))
MENU_ZOOM = zoomed(2000, (0.6, 0.74), at=(540, 800))

SHOTS = [
    Shot("01Feed", 4, 12, 0.6, HERO, enter="rise", exit="left"),
    Shot("01Feed", 12, 20, 10.1, HERO_RIGHT, enter="right", exit="left"),
    Shot("02Filter", 20, 26.5, 0.2, HERO_LEFT, enter="right", exit="none", speed=1.5),
    Shot("02Filter", 26.5, 33, 10.0, HERO_LEFT, enter="none", exit="down"),

    Shot("04Stats", 36, 44, 1.4, HERO, enter="pop", exit="left", pulse=True,
         moves=(Move(40.4, 42.2, STRIP_ZOOM),)),
    Shot("04Stats", 44, 52, 10.0, HERO_RIGHT, enter="right", exit="left", pulse=True,
         moves=(Move(47.2, 49.0, NORA_ZOOM),)),
    Shot("03ComposeMenu", 52, 60, 1.56, HERO_LEFT, enter="right", exit="left", pulse=True,
         moves=(Move(54.6, 56.4, MENU_ZOOM),)),
    Shot("05Thread", 60, 68, 0.9, HERO_RIGHT, enter="right", exit="down", pulse=True, speed=1.4),

    Shot("06Profile", 68, 75, 3.2, HERO, enter="pop", exit="left", pulse=True, speed=2.2),
    Shot("07Ask", 75, 84, 1.3, HERO_RIGHT, enter="right", exit="left", pulse=True, speed=2.5),
    Shot("08Settings", 84, 91.5, 0.2, HERO_LEFT, enter="right", exit="down", pulse=True, speed=1.7),

    Shot("01Feed", 91, 98.5, 14.0, TRIPLE_LEFT, enter="left", exit="down", pulse=True),
    Shot("04Stats", 91.5, 98.5, 12.0, TRIPLE_RIGHT, enter="right", exit="down", pulse=True),
    Shot("05Thread", 91, 98.5, 6.0, TRIPLE_MID, enter="drop", exit="down", pulse=True),
]

CAPTIONS = [
    Caption("Your timeline.", 0.4, 4, y=560, size=104),
    Caption("Minus the *rage*.", 2, 4, y=700, size=104),

    Caption("A calmer way to read X.", 4.6, 12),
    Caption("Photos and video *fit* their shape.", 12.6, 20),
    Caption("Rage-bait is *hidden*\nbefore you see it.", 20.6, 26.5, y=130),
    Caption("See what it hid, and why.\nOne tap brings it back.", 26.6, 33, y=130),

    Caption("Built for iPhone.", 32.6, 36, y=560, size=104),
    Caption("Every detail *considered*.", 34, 36, y=700, size=70),

    Caption("Tap views for *the numbers*.", 36.2, 44, plate=190),
    Caption("Your own posts get X's *analytics*.", 44.2, 52, plate=190),
    Caption("Touch and hold *Compose*.", 52.2, 60, plate=190),
    Caption("Threads that *read* like threads.", 60.2, 68),

    Caption("Profiles with *depth*.", 68.2, 75, accent=SUN),
    Caption("Ask a model about any post.", 75.2, 84, accent=SUN),
    Caption("Make it *yours*.", 84.2, 91.5, accent=SUN),
    Caption("Calm, all the way down.", 91.8, 98, accent=SUN),

    Caption("unrager", 99.2, 108, y=780, size=150),
    Caption("Take the *rage* out of your timeline.", 100.2, 108, y=905, size=50, weight="Medium"),
    Caption("Free and open source", 101.2, 108, y=1015, size=40, weight="Medium", color=(255, 255, 255, 190)),
    Caption("github.com/guitaripod/unrager", 101.8, 108, y=1075, size=40, weight="SemiBold", color=SKY),
]

APP_ICON = AppIcon(beat_in=98.2, cx=540, cy=470, size=300)
RINGS = [(36, 0.7), (68, 0.7), (98, 0.5)] + [(b, 0.28) for b in range(40, 68, 4)] + \
        [(b, 0.28) for b in range(72, 98, 4)]
FLASHES = [(36, 0.85), (68, 0.95), (98, 0.5)]
