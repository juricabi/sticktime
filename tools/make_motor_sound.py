#!/usr/bin/env python3
"""Synthesize StickTime's motor sound: short WAV clips the game plays back to back.

A Lua script on EdgeTX gets one sine tone (playTone) or WAV files (playFile), and EdgeTX
plays queued files back to back. So the motor sound is rendered here at 16 levels of motor
speed (idle to full throttle), four takes each, 0.1 s per clip, and the game queues a clip
for the current motor speed, in a take picked at random, about every 0.1 s.

What a quad sounds like, and what each clip holds:
- the props' blade-pass tone (3 blades) with its harmonics: the buzz;
- the shaft frequency and its second harmonic: the growl under it;
- the motors' electrical whine (7 pole pairs);
- air rush: broadband noise, nearly flat up to 6 kHz, that grows with motor speed;
- four motors that add up a little differently in every take (and in two takes one motor
  runs slightly faster, a gentle beat), so takes picked at random give the loudness and
  timbre the slow, irregular wobble of real rotors (measured against recordings of real
  quadcopters: their sound wobbles at a few Hz, not regularly).

Every tone has a whole number of cycles in a clip and starts and ends at a zero crossing, so
clips join without a click whatever the level and take before and after; the noise fades in
and out over 0.5 ms at the ends. A clip is 1599 samples at 16 kHz, one sample short of
0.1 s: EdgeTX then finishes it inside its last 10 ms audio buffer and starts the next clip in
the next one, without a silent buffer between them.

usage: python3 tools/make_motor_sound.py [out_dir] [--preview file.wav]
"""
import argparse
import pathlib
import wave

import numpy as np

SR = 16000                    # sample rate (EdgeTX: 8, 16 or 32 kHz, 16-bit mono PCM)
N = 1599                      # samples per clip
GRID = SR / N                 # tones must be multiples of this (whole cycles per clip)
LEVELS = 16
TAKES = "abcd"
R0 = 0.12                     # motor speed at idle (1.5% thrust: sqrt(0.015)) as a fraction of full


def level_speed(i):
    """motor speed (0..1 of full) of level i (0-based)"""
    return R0 + (1 - R0) * i / (LEVELS - 1)


def blade_pass(r):
    """blade-pass frequency at motor speed r: 108 Hz at idle, 400 Hz in a hover, 900 Hz flat out"""
    return 900.0 * r


def sine(k, t):
    """a tone of k whole cycles per clip: zero at both ends"""
    return np.sin(2 * np.pi * k * GRID * t)


def clip(i, take):
    ti = TAKES.index(take)
    rng = np.random.default_rng(1000 + i * 31 + ti)       # this clip's air noise
    voice = np.random.default_rng(77 + ti)                 # this take's motor mix, the same at every level
    gains = voice.uniform(0.75, 1.15, 4)
    signs = voice.choice([-1.0, 1.0], size=(4, 16))
    r = level_speed(i)
    t = np.arange(N) / SR
    out = np.zeros(N)
    k0 = max(2, int(round(blade_pass(r) / GRID)))
    for m in range(4):
        # takes b and d: one motor a step (10 Hz) faster or slower, and quieter: a gentle beat
        off = (1 if m == 1 else 0) if take == "b" else (-1 if m == 3 else 0) if take == "d" else 0
        k = k0 + off
        g = gains[m] * (0.4 if off else 1.0)
        # blade-pass buzz: harmonics falling like a sawtooth's, softened above 4 kHz
        for n in range(1, 11):
            f = n * k * GRID
            if f > 7000:
                break
            out += signs[m, n] * g / n / (1 + (f / 4000) ** 2) * sine(n * k, t)
        # shaft growl: the shaft turns at a third of the blade-pass frequency
        ks = max(1, int(round(k / 3)))
        out += g * (signs[m, 11] * 0.20 * sine(ks, t) + signs[m, 12] * 0.10 * sine(2 * ks, t))
        # electrical whine: 7 pole pairs, so 7x the shaft frequency
        if 7 * ks * GRID < 7000:
            out += signs[m, 13] * (0.05 + 0.10 * r) * g * sine(7 * ks, t)
        if 14 * ks * GRID < 7000:
            out += signs[m, 14] * 0.03 * r * g * sine(14 * ks, t)
    # air rush: noise from 150 Hz to 7 kHz, nearly flat, with a broad hump around 2.5x the
    # blade-pass frequency; about as strong as the tones, more so at speed
    spec = np.zeros(N // 2 + 1, complex)
    f = np.arange(N // 2 + 1) * GRID
    band = (f > 150) & (f < 7000)
    hump = 1 + 1.2 * np.exp(-((np.log(np.maximum(f, 1)) - np.log(2.5 * blade_pass(r))) ** 2) / 0.6)
    mag = np.where(band, hump * (np.maximum(f, 1) / 1000) ** -0.1 / (1 + (f / 6000) ** 4), 0)
    spec[band] = mag[band] * np.exp(2j * np.pi * rng.random(band.sum()))
    noise = np.fft.irfft(spec, N)
    tonal_rms = np.sqrt(np.mean(out ** 2))
    noise *= (0.6 + 0.45 * r) * tonal_rms / max(np.sqrt(np.mean(noise ** 2)), 1e-9)
    ramp = 8
    w = np.ones(N)
    w[:ramp] = 0.5 - 0.5 * np.cos(np.pi * np.arange(ramp) / ramp)
    w[-ramp:] = w[:ramp][::-1]
    out += noise * w
    # louder with speed
    return out * (0.30 + 0.70 * r ** 1.3)


def write_wav(path, samples):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(samples.astype("<i2").tobytes())


def render():
    clips = {(i, k): clip(i, k) for i in range(LEVELS) for k in TAKES}
    peak = max(np.max(np.abs(c)) for c in clips.values())
    scale = 0.92 * 32767 / peak
    return {key: np.round(c * scale) for key, c in clips.items()}


# the takes in the order the game picks them: x = x * 11 % 251 runs through 1..250 before it
# repeats (11 is a primitive root of 251), take = x % 4 (see motorSound in the game)
TAKE_SEQ = []
_x = 1
for _ in range(250):
    _x = _x * 11 % 251
    TAKE_SEQ.append(_x % 4)


def preview(clips, path):
    """a short flight, the way the game queues the clips: idle, a climb to a hover, a hover,
    a punch-out, a drop, then flips; written at 32 kHz with each sample doubled, as EdgeTX
    plays a 16 kHz file"""
    thr = []
    def seg(a, b, secs):
        n = int(secs * 10)
        thr.extend(np.linspace(a, b, n, endpoint=False))
    seg(0.0, 0.0, 1.0)
    seg(0.0, 0.2, 1.5)
    seg(0.2, 0.2, 2.0)
    seg(0.2, 1.0, 0.3)
    seg(1.0, 1.0, 1.5)
    seg(1.0, 0.0, 0.2)
    seg(0.0, 0.0, 1.2)
    for _ in range(3):
        seg(0.6, 0.6, 0.4)
        seg(0.1, 0.1, 0.4)
    seg(0.2, 0.2, 1.5)
    out = []
    for j, th in enumerate(thr):
        r = np.sqrt(0.015 + 0.985 * th)      # thrust share -> motor speed, as in the game
        lv = int(np.clip(np.floor((r - R0) * (LEVELS - 1) / (1 - R0) + 0.5), 0, LEVELS - 1))
        out.append(clips[(lv, TAKES[TAKE_SEQ[j % len(TAKE_SEQ)]])])
    x = np.repeat(np.concatenate(out), 2)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(32000)
        w.writeframes(x.astype("<i2").tobytes())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default=str(pathlib.Path(__file__).resolve().parents[1]
                                                  / "sdcard/SCRIPTS/TOOLS/StickTimeSound"))
    ap.add_argument("--preview")
    a = ap.parse_args()
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    clips = render()
    for (i, k), c in clips.items():
        write_wav(out / f"m{i + 1:02d}{k}.wav", c)
    print(f"{out}: {len(clips)} clips of {N} samples at {SR} Hz "
          f"({sum((out / f'm{i + 1:02d}{k}.wav').stat().st_size for (i, k) in clips) // 1024} KB)")
    if a.preview:
        preview(clips, a.preview)
        print("preview:", a.preview)


if __name__ == "__main__":
    main()
