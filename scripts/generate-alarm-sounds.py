#!/usr/bin/env python3
"""Generate the bundled reset-alarm tones for the iOS companion app.

Why this exists
---------------
`ResetAlarmSound` names macOS system sounds ("Glass", "Submarine", "Frog",
"Blow", "Bottle", "Tink", "Sosumi").  Those live in
`/System/Library/Sounds/` and `NSSound(named:)` resolves them on macOS.

iOS has no such catalogue.  `UNNotificationSound(named:)` on iOS resolves only
the app's own bundled audio or the default chime, so a tone named "Glass" is
silently unresolvable and a real reset alert on the iPhone makes no sound at
all.  Shipping Apple's system sounds inside the app was rejected as a
licensing question, so each tone is synthesised here instead: a short
characteristic rendition of the same idea, with the same picker labels.

Run from the repo root:

    python3 scripts/generate-alarm-sounds.py

Output lands in ios/CodeCapsCompanion/App/Resources/, is committed, and is
picked up by project.yml's `sources: - path: App` without any extra wiring.
Re-run only when a tone needs to change; the output is deterministic, so a
re-run on an unchanged tone produces byte-identical files.

`systemDefault` and `silent` deliberately have no file: the first uses the
platform default chime and the second is mute.
"""

from __future__ import annotations

import math
import os
import struct
import wave

SAMPLE_RATE = 44_100
OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "ios", "CodeCapsCompanion", "App", "Resources",
)


def _env(t: float, freq: float, partial: int = 1) -> float:
    return math.sin(2.0 * math.pi * freq * partial * t)


def _adsr(n: int, attack: float, decay: float) -> list[float]:
    """A minimal attack/decay envelope, normalised to peak 1.0."""
    a = max(1, int(attack * n))
    d = max(1, int(decay * n))
    out = [0.0] * n
    for i in range(n):
        if i < a:
            out[i] = i / a
        elif i < a + d:
            out[i] = 1.0 - (1.0 - math.exp(-3.0 * (i - a) / d)) * 1.0
        else:
            out[i] = 0.0
    return out


def _render(samples: list[float]) -> bytes:
    """Clamp, normalise to 0.89 of full scale, and pack to 16-bit mono."""
    peak = max((abs(s) for s in samples), default=0.0)
    if peak > 0:
        samples = [s / peak * 0.89 for s in samples]
    frames = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32_767)) for s in samples)
    return frames


def _write(name: str, samples: list[float]) -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(_render(samples))
    print(f"wrote {os.path.relpath(path)} ({os.path.getsize(path)} bytes)")


def glass(dur=0.42):
    """A bright tap: high partials, fast decay."""
    n = int(dur * SAMPLE_RATE)
    env = _adsr(n, 0.002, 0.16)
    return [env[i] * (_env(i / SAMPLE_RATE, 2_600) * 0.5
                      + _env(i / SAMPLE_RATE, 3_900, 2) * 0.25
                      + _env(i / SAMPLE_RATE, 5_200, 3) * 0.12)
            for i in range(n)]


def submarine(dur=0.85):
    """A low, longer tone that rises as it sounds."""
    n = int(dur * SAMPLE_RATE)
    out = []
    for i in range(n):
        t = i / SAMPLE_RATE
        f = 180.0 + 70.0 * (t / dur)
        env = math.exp(-2.4 * t / dur)
        out.append(env * (_env(t, f) * 0.7 + _env(t, f, 2) * 0.2))
    return out


def frog(dur=0.62):
    """Two short low chirps."""
    n = int(dur * SAMPLE_RATE)
    out = [0.0] * n
    for start, length, f0, f1 in ((0.02, 0.16, 430, 320), (0.30, 0.20, 360, 250)):
        s0 = int(start * SAMPLE_RATE)
        seg = int(length * SAMPLE_RATE)
        for i in range(seg):
            if s0 + i >= n:
                break
            t = i / SAMPLE_RATE
            f = f0 + (f1 - f0) * (t / length)
            env = math.sin(math.pi * min(1.0, t / length)) ** 0.7
            out[s0 + i] = env * (_env(t, f) * 0.8 + _env(t, f, 2) * 0.15)
    return out


def blow(dur=0.55):
    """An airy puff: filtered noise with a soft envelope."""
    n = int(dur * SAMPLE_RATE)
    out = []
    seed = 12345
    prev = 0.0
    for i in range(n):
        seed = (1103515245 * seed + 12345) & 0x7FFFFFFF
        white = (seed / 0x3FFFFFFF) - 1.0
        prev = prev * 0.72 + white * 0.28          # one-pole low-pass
        t = i / SAMPLE_RATE
        env = math.sin(math.pi * min(1.0, t / dur)) ** 1.6
        out.append(env * prev * 0.9)
    return out


def bottle(dur=0.30):
    """A cork pop: very short, bright, fast decay."""
    n = int(dur * SAMPLE_RATE)
    env = _adsr(n, 0.001, 0.05)
    return [env[i] * (_env(i / SAMPLE_RATE, 1_150) * 0.7
                      + _env(i / SAMPLE_RATE, 2_300, 2) * 0.3)
            for i in range(n)]


def tink(dur=0.50):
    """A small bell: two inharmonic partials, quick decay."""
    n = int(dur * SAMPLE_RATE)
    out = []
    for i in range(n):
        t = i / SAMPLE_RATE
        env = math.exp(-9.0 * t)
        out.append(env * (_env(t, 3_000) * 0.6 + _env(t, 4_520) * 0.25 + _env(t, 6_100) * 0.1))
    return out


def sosumi(dur=0.80):
    """The classic Mac alert shape: a short rising three-note figure."""
    n = int(dur * SAMPLE_RATE)
    out = [0.0] * n
    for start, length, freq in ((0.0, 0.16, 784.0), (0.17, 0.16, 988.0), (0.34, 0.30, 1_318.0)):
        s0 = int(start * SAMPLE_RATE)
        seg = int(length * SAMPLE_RATE)
        for i in range(seg):
            if s0 + i >= n:
                break
            t = i / SAMPLE_RATE
            env = math.exp(-5.0 * t / length)
            out[s0 + i] = env * (_env(t, freq) * 0.6
                                + _env(t, freq, 2) * 0.22
                                + _env(t, freq, 3) * 0.08)
    return out


TONES = {
    "alarm-glass.wav": glass,
    "alarm-submarine.wav": submarine,
    "alarm-frog.wav": frog,
    "alarm-blow.wav": blow,
    "alarm-bottle.wav": bottle,
    "alarm-tink.wav": tink,
    "alarm-sosumi.wav": sosumi,
}

if __name__ == "__main__":
    for filename, fn in TONES.items():
        _write(filename, fn())
    print(f"\n{len(TONES)} tones written to {OUT_DIR}")
    print("systemDefault and silent have no file by design: the platform default\n"
          "chime and no chime at all are both expressed without bundled audio.")
