# Builds vo.wav (voiceover on the timeline) and music.wav (score + SFX) for the intro.
import subprocess, wave, sys, os
import numpy as np
from scipy import signal

SR = 48000
T = 40.0
N = int(SR * T)
HERE = os.path.dirname(os.path.abspath(__file__))
rng = np.random.default_rng(7)
t = np.arange(N) / SR


def load_mp3(path):
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-f', 's16le', '-ac', '1', '-ar', str(SR), '-'],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.int16).astype(np.float32) / 32768


def write(path, x):
    x = np.clip(x, -1, 1)
    if x.ndim == 1:
        x = np.stack([x, x], 1)
    with wave.open(path, 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((x * 32767).astype(np.int16).tobytes())


def place(buf, x, at, gain=1.0):
    i = int(at * SR)
    j = min(len(buf), i + len(x))
    buf[i:j] += x[:j - i] * gain


def lp(x, f, o=2):
    return signal.sosfilt(signal.butter(o, f, 'low', fs=SR, output='sos'), x)


def hp(x, f, o=2):
    return signal.sosfilt(signal.butter(o, f, 'high', fs=SR, output='sos'), x)


def bp(x, lo, hi, o=2):
    return signal.sosfilt(signal.butter(o, [lo, hi], 'band', fs=SR, output='sos'), x)


hz = lambda m: 440 * 2 ** ((m - 69) / 12)

# ---------------- voiceover
VO_AT = [0.8, 3.0, 8.4, 13.2, 18.7, 23.7, 31.2, 34.2]
vo = np.zeros(N, np.float32)
for k, at in enumerate(VO_AT, 1):
    place(vo, load_mp3(os.path.join(HERE, 'vo', f'{k}.mp3')), at)
write(os.path.join(HERE, 'vo.wav'), vo)

# ---------------- music
L = np.zeros(N); Rr = np.zeros(N)
BPM = 100; BEAT = 60 / BPM; GRID0 = 8.45


def saw(f, dur, harm=7):
    tt = np.arange(int(dur * SR)) / SR
    return sum(np.sin(2 * np.pi * f * k * tt) / k for k in range(1, harm + 1))


def env(n, a, r, sus=1.0):
    e = np.ones(n) * sus
    na, nr = int(a * SR), int(r * SR)
    e[:na] = np.linspace(0, sus, na)
    e[-nr:] *= np.linspace(1, 0, nr)
    return e


# intro drone (0 - 8.45): low A with slow beating, plus rising warning tone under the disk gauge
dr_n = int(9.2 * SR); dt = np.arange(dr_n) / SR
drone = (np.sin(2 * np.pi * 55 * dt) + .5 * np.sin(2 * np.pi * 82.6 * dt) + .3 * np.sin(2 * np.pi * 110.4 * dt))
drone *= env(dr_n, 1.5, 1.2) * (0.75 + .25 * np.sin(2 * np.pi * .5 * dt))
drone = lp(drone, 500) * .16
place(L, drone, 0); place(Rr, drone, 0)
wn = int(2.2 * SR); wt = np.arange(wn) / SR
f = 180 + 420 * (wt / 2.2) ** 2
warn = np.sin(2 * np.pi * np.cumsum(f) / SR) * env(wn, .4, .5) * .05
place(L, warn, .2); place(Rr, warn, .2)

# chord pad from the logo hit onward
CH = [(GRID0, [57, 60, 64, 69]), (GRID0 + 4.8, [53, 57, 60, 65]), (GRID0 + 9.6, [48, 55, 60, 64]),
      (GRID0 + 14.4, [55, 59, 62, 67]), (GRID0 + 19.2, [57, 60, 64, 69]), (GRID0 + 24.0, [53, 57, 60, 64]),
      (GRID0 + 28.8, [48, 55, 60, 64])]
for i, (st, notes) in enumerate(CH):
    dur = (CH[i + 1][0] - st if i + 1 < len(CH) else T - st) + .8
    for m in notes:
        for det, ch in ((1.0015, L), (0.9985, Rr)):
            x = saw(hz(m) * det, dur, 5) * env(int(dur * SR), .6, .9) * .028
            place(ch, x, st)
    bass = saw(hz(notes[0] - 12), dur, 3) * env(int(dur * SR), .05, .6) * .09
    place(L, bass, st); place(Rr, bass, st)
L = lp(L, 2200); Rr = lp(Rr, 2200)

# pump the pad on every beat (classic sidechain feel)
beats = np.arange(GRID0, 37.5, BEAT)
pump = np.ones(N)
for b in beats:
    i = int(b * SR); n = int(.35 * SR)
    pump[i:i + n] = np.minimum(pump[i:i + n], 1 - .45 * np.exp(-np.arange(n) / SR / .11))
mask = t >= GRID0 - .05
L[mask] *= pump[mask]; Rr[mask] *= pump[mask]


def kick():
    n = int(.4 * SR); kt = np.arange(n) / SR
    fr = 45 + 90 * np.exp(-kt / .03)
    return np.sin(2 * np.pi * np.cumsum(fr) / SR) * np.exp(-kt / .12) * .32


def hat():
    n = int(.05 * SR)
    return hp(rng.standard_normal(n), 7000) * np.exp(-np.arange(n) / SR / .012) * .05


K, H = kick(), hat()
for b in beats:
    if b > 33.3 and b < 34.0:  # drop out before the outro hit
        continue
    place(L, K, b); place(Rr, K, b)
for b in beats:
    if 13.0 < b < 33.3:
        place(L, H, b + BEAT / 2, .9); place(Rr, H, b + BEAT / 2, 1.1)


# ---------------- SFX
def whoosh(dur=.7, lo=300, hi=5000, g=.18):
    n = int(dur * SR); x = rng.standard_normal(n)
    sweep = lo * (hi / lo) ** (np.linspace(0, 1, n) ** 1.5)
    out = np.zeros(n); blk = 1200
    for s in range(0, n, blk):
        c = sweep[min(s + blk // 2, n - 1)]
        out[s:s + blk] = bp(x[s:s + blk], max(80, c * .6), min(SR / 2 - 100, c * 1.4), 1)
    e = np.sin(np.pi * np.linspace(0, 1, n)) ** 2
    return out * e * g


def impact(g=1.0):
    n = int(2.5 * SR); it = np.arange(n) / SR
    fr = 32 + 70 * np.exp(-it / .08)
    sub = np.sin(2 * np.pi * np.cumsum(fr) / SR) * np.exp(-it / .7)
    noise = lp(rng.standard_normal(n), 3000) * np.exp(-it / .25) * .35
    return (sub * .55 + noise) * g


def riser(dur, g=.2):
    n = int(dur * SR); x = rng.standard_normal(n)
    out = np.zeros(n); blk = 1200
    for s in range(0, n, blk):
        c = 200 * (40 ** (s / n))
        out[s:s + blk] = bp(x[s:s + blk], c * .7, min(c * 1.5, SR / 2 - 100), 1)
    return out * np.linspace(0, 1, n) ** 2.5 * g


def click():
    n = int(.03 * SR); ct = np.arange(n) / SR
    return (np.sin(2 * np.pi * 2400 * ct) * .5 + hp(rng.standard_normal(n), 3000) * .5) * np.exp(-ct / .004) * .35


def tap(f):
    n = int(.12 * SR); ct = np.arange(n) / SR
    return (np.sin(2 * np.pi * f * ct) * np.exp(-ct / .03) + lp(rng.standard_normal(n), 1800) * np.exp(-ct / .01) * .4) * .09


def ding():
    n = int(1.2 * SR); ct = np.arange(n) / SR
    return (np.sin(2 * np.pi * 1318.5 * ct) * np.exp(-ct / .35) + .6 * np.sin(2 * np.pi * 1975.5 * ct) * np.exp(-ct / .25)) * .06


def chime(notes, at, step=.07, g=.05):
    for i, m in enumerate(notes):
        n = int(1.5 * SR); ct = np.arange(n) / SR
        x = (np.sin(2 * np.pi * hz(m) * ct) + .3 * np.sin(4 * np.pi * hz(m) * ct)) * np.exp(-ct / .45) * g
        place(L, x, at + i * step, 1.1 if i % 2 else .9); place(Rr, x, at + i * step, .9 if i % 2 else 1.1)


sfx = np.zeros(N)
place(sfx, ding(), 1.35)
for at in (2.75, 12.8, 18.5, 23.55, 31.05, 33.5):
    place(sfx, whoosh(), at)
place(sfx, riser(1.9), 6.55)
place(sfx, impact(), 8.42)
place(sfx, riser(1.2, .12), 32.85)
place(sfx, impact(.8), 34.02)
for c in (17.38, 18.55, 19.6, 22.3, 33.1):
    place(sfx, click(), c)
# chips landing (same schedule as the animation)
for i in range(26):
    td = 3.12 + i * .14 if i < 3 else 3.94 + (i - 3) * .13 if i < 6 else 4.62 + (i - 6) * .2 if i < 9 else 5.3 + (i - 9) * .115
    place(sfx, tap(300 + (i * 37) % 260), td + .42)
chime([69, 72, 76, 81], 17.85)          # cleaned
chime([72, 76, 79], 22.6, g=.04)         # uninstalled
chime([69, 76, 81, 84, 88], 35.25, .33, .035)  # pills

# simple reverb for the music bus
ir_n = int(1.8 * SR)
ir = rng.standard_normal(ir_n) * np.exp(-np.arange(ir_n) / SR / .45)
ir = lp(ir, 4000); ir /= np.abs(ir).sum() / 6
wetL = signal.fftconvolve(L, ir)[:N] * .25
wetR = signal.fftconvolve(Rr, np.roll(ir, 300))[:N] * .25
music = np.stack([L + wetL + sfx, Rr + wetR + sfx], 1)
fade = np.clip((T - t) / 2.2, 0, 1)[:, None]
music *= fade
music /= max(1e-6, np.abs(music).max()) / .8
write(os.path.join(HERE, 'music.wav'), music)
print('ok')
