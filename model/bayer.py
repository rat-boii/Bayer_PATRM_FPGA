"""Bayer RGGB reference model (step 1.3), built on model/patrm.py.

The raw mosaic (H, W) is split into four planes of size (H/2, W/2):
    R = (even row, even col)  o = (0, 0)      Gr = (even, odd)  o = (0, 1)
    Gb = (odd, even)          o = (1, 0)      B  = (odd, odd)   o = (1, 1)
Each plane is warped as an independent grayscale image (D1 uses the plane size) with
    b_p = (b11, b12, T_px, b21, b22, T_py),  T_p = ((A - I) o + t) >> 1   (D2, integers, floor)
and the planes are merged back. Option B's RTL adds the lane offset T_p - T_R (D6) to the R coordinates.
"""

import numpy as np

from model import patrm as P

PLANES = ("R", "Gr", "Gb", "B")
OFFSETS = {"R": (0, 0), "Gr": (0, 1), "Gb": (1, 0), "B": (1, 1)}   # (row, col)


def split_rggb(raw, W, H):
    """raw uint8 (H, W) RGGB mosaic -> dict of four (H/2, W/2) planes."""
    P.check_size(W, H, "bayer")
    raw = np.asarray(raw)
    if raw.shape != (H, W):
        raise ValueError(f"raw shape {raw.shape} does not match H x W = {H} x {W}")
    return {p: np.ascontiguousarray(raw[o[0]::2, o[1]::2]) for p, o in OFFSETS.items()}


def merge_rggb(planes, W, H):
    """Inverse of split_rggb."""
    P.check_size(W, H, "bayer")
    out = np.empty((H, W), dtype=np.uint8)
    for p, o in OFFSETS.items():
        if planes[p].shape != (H // 2, W // 2):
            raise ValueError(f"plane {p} has shape {planes[p].shape}, expected {(H // 2, W // 2)}")
        out[o[0]::2, o[1]::2] = planes[p]
    return out


def plane_shifts(b):
    """D2: T_p for every plane, as Q15.16 integers (python >> = arithmetic shift = floor)."""
    b11, b12, b13, b21, b22, b23 = (int(c) for c in b)
    one = P.ONE
    T = {
        "R": (b13 >> 1, b23 >> 1),
        "Gr": ((b13 + b12) >> 1, (b23 + b22 - one) >> 1),
        "Gb": ((b13 + b11 - one) >> 1, (b23 + b21) >> 1),
        "B": ((b13 + b11 + b12 - one) >> 1, (b23 + b21 + b22 - one) >> 1),
    }
    for p, (tx, ty) in T.items():
        if not (P.INT32_MIN <= tx <= P.INT32_MAX and P.INT32_MIN <= ty <= P.INT32_MAX):
            raise ValueError(f"T_{p} = ({tx}, {ty}) does not fit in signed 32 bits")
    return T


def plane_b(b, T=None):
    """Per-plane coefficient sets b_p = (b11, b12, T_px, b21, b22, T_py)."""
    if T is None:
        T = plane_shifts(b)
    b11, b12, _, b21, b22, _ = (int(c) for c in b)
    return {p: (b11, b12, T[p][0], b21, b22, T[p][1]) for p in PLANES}


def lane_offsets(b):
    """D6: register differences T_p - T_R for Gr, Gb, B. Never recompute as (A-I)o/2."""
    T = plane_shifts(b)
    return {p: (T[p][0] - T["R"][0], T[p][1] - T["R"][1]) for p in ("Gr", "Gb", "B")}


def check_bayer_transform(b, W, H):
    """D4 at full size and for every plane at plane size."""
    P.check_transform(b, W, H)
    for p, bp in plane_b(b).items():
        try:
            P.check_transform(bp, W // 2, H // 2)
        except ValueError as e:
            raise ValueError(f"plane {p}: {e}") from None


def warp_bayer(raw, W, H, b):
    """Plane-wise warp of an RGGB mosaic. Returns uint8 (H, W) RGGB mosaic."""
    P.check_size(W, H, "bayer")
    check_bayer_transform(b, W, H)
    planes = split_rggb(raw, W, H)
    bp = plane_b(b)
    out = {p: P.warp_gray(planes[p], W // 2, H // 2, bp[p]) for p in PLANES}
    return merge_rggb(out, W, H)


# ---------------------------------------------------------------------------
# Helpers for figures and quality checks (information only, not part of the hardware reference)
# ---------------------------------------------------------------------------

def _conv3(img, k):
    """3x3 correlation with zero padding, float64."""
    H, W = img.shape
    pad = np.pad(img, 1)
    out = np.zeros((H, W), dtype=np.float64)
    for di in range(3):
        for dj in range(3):
            if k[di][dj]:
                out += k[di][dj] * pad[di:di + H, dj:dj + W]
    return out


def demosaic_bilinear(raw):
    """Simple bilinear demosaic of an RGGB mosaic (normalised convolution, so borders are handled).
    Returns float64 (H, W, 3) in 0..255."""
    raw = np.asarray(raw, dtype=np.float64)
    H, W = raw.shape
    u, v = np.meshgrid(np.arange(H), np.arange(W), indexing="ij")
    masks = [((u % 2 == 0) & (v % 2 == 0)),
             ((u % 2) != (v % 2)),
             ((u % 2 == 1) & (v % 2 == 1))]
    k_rb = [[1, 2, 1], [2, 4, 2], [1, 2, 1]]
    k_g = [[0, 1, 0], [1, 4, 1], [0, 1, 0]]
    out = np.empty((H, W, 3))
    for c, (m, k) in enumerate(zip(masks, (k_rb, k_g, k_rb))):
        m = m.astype(np.float64)
        out[..., c] = _conv3(raw * m, k) / _conv3(m, k)
    return out
