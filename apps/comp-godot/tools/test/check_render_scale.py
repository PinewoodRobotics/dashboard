# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy==2.2.6", "pillow==11.3.0"]
# ///
"""Proves a HUD screenshot taken at render scale 0.5 had its 3D drawn at half
resolution: in the minimap's interior, the share of spectral energy above half
the pixel Nyquist frequency (0.25 cycles/px) must drop below 0.22 of the
render scale 1.0 shot of the same frozen fixture (0.5 measures about 0.15,
0.75 about 0.33), while the low-frequency content stays the same picture.

Usage: check_render_scale.py FULL.png HALF.png
"""

import sys

import numpy as np
from PIL import Image

# Interior of the HUD minimap (x 540..1380, y 480..1080 at 1920x1080), away
# from the rounded frame and the vignette.
CROP = (660, 560, 1260, 1000)


def gray(path: str) -> np.ndarray:
    img = Image.open(path).convert("L")
    assert img.size == (1920, 1080), f"{path}: {img.size}, want 1920x1080"
    return np.asarray(img.crop(CROP), dtype=np.float64) / 255.0


def high_share(a: np.ndarray) -> float:
    a = a - a.mean()
    win = np.outer(np.hanning(a.shape[0]), np.hanning(a.shape[1]))
    p = np.abs(np.fft.fft2(a * win)) ** 2
    fy = np.fft.fftfreq(a.shape[0])[:, None]
    fx = np.fft.fftfreq(a.shape[1])[None, :]
    r = np.sqrt(fx**2 + fy**2)
    return float(p[r > 0.25].sum() / p.sum())


def low(a: np.ndarray) -> np.ndarray:
    h, w = (a.shape[0] // 8) * 8, (a.shape[1] // 8) * 8
    return a[:h, :w].reshape(h // 8, 8, w // 8, 8).mean(axis=(1, 3))


full, half = gray(sys.argv[1]), gray(sys.argv[2])
hf, hh = high_share(full), high_share(half)
corr = float(np.corrcoef(low(full).ravel(), low(half).ravel())[0, 1])
ok_res = hh < hf * 0.22
ok_same = corr > 0.97
print(f"{'ok  ' if ok_res else 'FAIL'} render scale 0.5 draws the 3D at half resolution: energy above 0.25 cycles/px "
      f"{hh:.5f} vs {hf:.5f} at 1.0 (ratio {hh / hf:.3f}, want < 0.22)")
print(f"{'ok  ' if ok_same else 'FAIL'} same picture at low frequency: correlation {corr:.4f} (want > 0.97)")
sys.exit(0 if ok_res and ok_same else 1)
