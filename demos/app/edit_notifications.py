"""The cut of the video about the iPhone app's remastered notifications.

Same machinery and song as `edit.py` (`UNRAGER_EDIT=edit_notifications python3
compose.py render`), a shorter story: what is new, the days, the filter chips,
what a row lets you do, and arrivals. The first drop of the song lands on beat
36 as the mentions feed comes up, and the second on beat 68 as the end card
comes up. Clips are `09NotifList` to `12NotifLive` from `prep.py`.
"""

from __future__ import annotations

from edit import *  # noqa: F401,F403
from edit import (BLAZE, CALM, LIFT, SKY, SUN, WHITE, AppIcon, BEAT_SECONDS, BEAT_ZERO, Caption, Layout,
                  Move, Section, Shot, zoomed)

LAST_BEAT = 80
DURATION = BEAT_ZERO + BEAT_SECONDS * LAST_BEAT

SECTIONS = [Section(0, CALM), Section(36, LIFT), Section(68, BLAZE)]

HERO = Layout(540, 830, 1200)
HERO_LEFT = Layout(560, 840, 1190, -2.5)
HERO_RIGHT = Layout(520, 840, 1190, 2.5)

DIGEST_ZOOM = zoomed(2150, (0.5, 0.25), at=(540, 640))
FOLLOW_ZOOM = zoomed(2000, (0.8, 0.69), at=(540, 830))

SHOTS = [
    Shot("09NotifList", 4, 10, 0.0, HERO, enter="rise", exit="left",
         moves=(Move(5.0, 6.4, DIGEST_ZOOM), Move(8.2, 9.6, HERO))),
    Shot("09NotifList", 10, 22, 2.6, HERO_RIGHT, enter="right", exit="left", speed=3.0),

    Shot("10NotifChips", 22, 28, 3.8, HERO_LEFT, enter="right", exit="none", speed=2.9),
    Shot("10NotifChips", 28, 38, 12.3, HERO_LEFT, enter="none", exit="left", pulse=True, speed=1.79),

    Shot("11NotifActions", 38, 45, 3.3, HERO, enter="pop", exit="left", pulse=True, speed=1.6,
         moves=(Move(39.0, 40.2, FOLLOW_ZOOM), Move(41.4, 42.6, HERO))),
    Shot("11NotifActions", 45, 50, 12.6, HERO_RIGHT, enter="right", exit="none", pulse=True, speed=1.5),
    Shot("11NotifActions", 50, 54, 19.4, HERO_RIGHT, enter="none", exit="left", pulse=True),

    Shot("12NotifLive", 54, 68, 5.0, HERO_LEFT, enter="right", exit="down", pulse=True, speed=2.6),
]

CAPTIONS = [
    Caption("Notifications.", 0.4, 4, y=560, size=104),
    Caption("*Remastered.*", 2, 4, y=700, size=104),

    Caption("Everything new, *at a glance*.", 4.4, 10, plate=190),
    Caption("Sorted into *days*.", 10.5, 22),

    Caption("Filter in *one tap*.", 22.4, 34.4),
    Caption("Mentions as *full posts*.", 34.6, 38.4),

    Caption("*Follow back* right there.", 38.6, 42.2, plate=190),
    Caption("Tap the faces for *everyone*.", 42.4, 45),
    Caption("Long-press for *more*.", 45.4, 50),
    Caption("Clear it all with *one tap*.", 50.2, 54, accent=SUN),

    Caption("New activity *glows in*.", 54.4, 60, accent=SUN),
    Caption("Scrolled away? A *pill* waits.", 60.2, 68, accent=SUN),

    Caption("unrager", 69.2, 80, y=780, size=150),
    Caption("Notifications, *remastered*.", 70.2, 80, y=905, size=50, weight="Medium"),
    Caption("Free and open source", 71.2, 80, y=1015, size=40, weight="Medium", color=(255, 255, 255, 190)),
    Caption("github.com/guitaripod/unrager", 71.8, 80, y=1075, size=40, weight="SemiBold", color=SKY),
]

APP_ICON = AppIcon(beat_in=68.2, cx=540, cy=470, size=300)
RINGS = [(36, 0.7), (68, 0.7)] + [(b, 0.28) for b in range(40, 68, 4)]
FLASHES = [(36, 0.85), (68, 0.95)]
