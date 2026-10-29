"""The cut of the video about the iPhone app's remastered Liked by list.

Same machinery and song as `edit.py` (`UNRAGER_EDIT=edit_likers python3
compose.py render`), a shorter story: touch and hold the heart, the load, who
follows you at a glance, following back, the rows narrowing and the chips. The
first drop of the song lands on beat 36 as Follow back is tapped, and the second
on beat 68 as the end card comes up. Clips are `13LikersLoad` to `15LikersChips`
from `prep.py`; a shot's `src` is a second of the trimmed clip.
"""

from __future__ import annotations

from edit import *  # noqa: F401,F403
from edit import (BLAZE, CALM, LIFT, SKY, SUN, AppIcon, BEAT_SECONDS, BEAT_ZERO, Caption, Layout,
                  Move, Section, Shot, zoomed)

LAST_BEAT = 80
DURATION = BEAT_ZERO + BEAT_SECONDS * LAST_BEAT

SECTIONS = [Section(0, CALM), Section(36, LIFT), Section(68, BLAZE)]

HERO = Layout(540, 830, 1200)
HERO_LEFT = Layout(560, 840, 1190, -2.5)
HERO_RIGHT = Layout(520, 840, 1190, 2.5)

RING_ZOOM = zoomed(2300, (0.45, 0.53), at=(540, 800))

SHOTS = [
    Shot("13LikersLoad", 4, 18, 1.0, HERO, enter="rise", exit="none", pulse=True, speed=1.0),
    Shot("13LikersLoad", 18, 36, 7.5, HERO, enter="none", exit="left", pulse=True, speed=1.6,
         moves=(Move(19.0, 20.6, RING_ZOOM), Move(25.0, 26.4, HERO))),

    Shot("14LikersFollowBack", 36, 44, 1.6, HERO_RIGHT, enter="pop", exit="none", pulse=True, speed=1.0),
    Shot("14LikersFollowBack", 44, 52, 7.0, HERO_RIGHT, enter="none", exit="none", pulse=True, speed=1.0,
         moves=(Move(44.4, 46.0, RING_ZOOM), Move(50.0, 51.4, HERO_RIGHT))),
    Shot("14LikersFollowBack", 52, 60, 12.0, HERO_RIGHT, enter="none", exit="left", pulse=True, speed=1.0),

    Shot("15LikersChips", 60, 68, 1.5, HERO_LEFT, enter="right", exit="down", pulse=True, speed=2.8),
]

CAPTIONS = [
    Caption("Liked by.", 0.4, 4, y=560, size=104),
    Caption("*Remastered.*", 2, 4, y=700, size=104),

    Caption("Touch and hold *the heart*.", 4.4, 10.2),
    Caption("It *loads* in one smooth motion.", 10.6, 18, plate=190),
    Caption("Who liked it, *at a glance*.", 18.4, 26.4, plate=190),
    Caption("Amber rings are followers\nyou haven't *followed back*.", 26.8, 36, y=130),

    Caption("*Follow back* in one tap.", 36.4, 44, plate=190, accent=SUN),
    Caption("The ring *moves with you*.", 44.4, 52, plate=190, accent=SUN),
    Caption("Tap a row to *see only them*.", 52.4, 60, plate=190, accent=SUN),
    Caption("Or narrow it *your way*.", 60.4, 68, accent=SUN),

    Caption("unrager", 69.2, 80, y=780, size=150),
    Caption("Liked by, *remastered*.", 70.2, 80, y=905, size=50, weight="Medium"),
    Caption("Free and open source", 71.2, 80, y=1015, size=40, weight="Medium", color=(255, 255, 255, 190)),
    Caption("github.com/guitaripod/unrager", 71.8, 80, y=1075, size=40, weight="SemiBold", color=SKY),
]

APP_ICON = AppIcon(beat_in=68.2, cx=540, cy=470, size=300)
RINGS = [(36, 0.7), (68, 0.7)] + [(b, 0.28) for b in range(40, 68, 4)]
FLASHES = [(36, 0.85), (68, 0.95)]
