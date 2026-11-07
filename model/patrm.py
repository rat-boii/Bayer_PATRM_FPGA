"""Grayscale fixed-point reference model of PATRM (step 1.1).

Conventions (see CLAUDE.md):
- x = row, y = column; u = output row, v = output column.
- b = (b11, b12, b13, b21, b22, b23) is the INVERSE mapping (output -> source), Q15.16 signed 32-bit:
      X = b11*u + b12*v + b13,   Y = b21*u + b22*v + b23
- D1 edge rule, D3 size rules, D4 corner check, D5 quantisation, D10 interpolator.
- Images are uint8 numpy arrays of shape (H, W), row-major.

Only the standard library and numpy are used.
"""

import argparse
import math
import sys

import numpy as np

FRAC_BITS = 16
ONE = 1 << FRAC_BITS            # 65536 = 1.0 in Q15.16
FRAC_MASK = ONE - 1
COORD_LIMIT_PX = 16384          # D4: corners must map inside +/- this many pixels
INT32_MIN = -(1 << 31)
INT32_MAX = (1 << 31) - 1


# ---------------------------------------------------------------------------
# Coefficients
# ---------------------------------------------------------------------------

def q16(v):
    """D5: quantise a float to Q15.16 with floor(v*65536 + 0.5)."""
    return int(math.floor(v * ONE + 0.5))


def quantise_b(b_float):
    """Quantise six float inverse coefficients to Q15.16 integers (D5)."""
    return tuple(q16(c) for c in b_float)


def make_b_float(W, H, rot_deg=0.0, sx=1.0, sy=1.0, shift=(0.0, 0.0),
                 mirror_rows=False, mirror_cols=False, about="centre"):
    """Inverse coefficients (floats, pixel units) from FORWARD parameters.

    Forward map (source point p -> output point q), with c the pivot:
        q = c + shift + R(rot) * S * M * (p - c)
    - R(rot): rotation, positive = counter-clockwise as the image is displayed (row axis points down):
              R = [[cos, -sin], [sin, cos]] acting on (row, col).
    - S = diag(sx, sy): sx scales rows (x), sy scales columns (y).
    - M = diag(-1 if mirror_rows, -1 if mirror_cols).
    - shift = (rows, cols) applied after rotation/scale; +rows moves content down.
    - about: "centre" -> c = ((H-1)/2, (W-1)/2); "origin" -> c = (0, 0).
    The inverse is p = c + Ainv * (q - c - shift), Ainv = (R S M)^-1, so
        [b11 b12; b21 b22] = Ainv,  (b13, b23) = c - Ainv (c + shift).
    """
    if sx == 0 or sy == 0:
        raise ValueError("scale must be non-zero")
    if about == "centre":
        cx, cy = (H - 1) / 2.0, (W - 1) / 2.0
    elif about == "origin":
        cx, cy = 0.0, 0.0
    else:
        raise ValueError("about must be 'centre' or 'origin'")
    th = math.radians(rot_deg)
    c, s = math.cos(th), math.sin(th)
    mr = -1.0 if mirror_rows else 1.0
    mc = -1.0 if mirror_cols else 1.0
    # Ainv = M^-1 S^-1 R^T  (M^-1 = M, R^-1 = R^T)
    a11 = mr / sx * c
    a12 = mr / sx * s
    a21 = mc / sy * (-s)
    a22 = mc / sy * c
    px, py = cx + shift[0], cy + shift[1]
    b13 = cx - (a11 * px + a12 * py)
    b23 = cy - (a21 * px + a22 * py)
    return (a11, a12, b13, a21, a22, b23)


def make_b(W, H, **forward):
    """Quantised Q15.16 inverse coefficients from forward parameters (see make_b_float)."""
    return quantise_b(make_b_float(W, H, **forward))


def check_size(W, H, mode="gray"):
    """D3 size rules. mode = 'gray' or 'bayer'. Raises ValueError on a bad size."""
    if not (isinstance(W, (int, np.integer)) and isinstance(H, (int, np.integer))) or W <= 0 or H <= 0:
        raise ValueError(f"image size must be positive integers, got W={W} H={H}")
    if mode == "gray":
        if W % 8 != 0:
            raise ValueError(f"D3: grayscale width must be a multiple of 8, got W={W} (W x H = {W}x{H})")
    elif mode == "bayer":
        if W % 16 != 0:
            raise ValueError(f"D3: Bayer width must be a multiple of 16, got W={W} (W x H = {W}x{H})")
        if H % 2 != 0:
            raise ValueError(f"D3: Bayer height must be even, got H={H} (W x H = {W}x{H})")
    else:
        raise ValueError(f"unknown mode {mode!r}")


def check_transform(b, W, H):
    """D4: raise if a coefficient does not fit in int32, or if any of the four output corners
    maps outside +/-16384 px (row or column). Exact integer arithmetic, no wrap."""
    if len(b) != 6:
        raise ValueError("b must have 6 coefficients")
    for name, c in zip(("b11", "b12", "b13", "b21", "b22", "b23"), b):
        if not (INT32_MIN <= int(c) <= INT32_MAX):
            raise ValueError(f"D4: {name}={c} does not fit in signed 32 bits")
    b11, b12, b13, b21, b22, b23 = (int(c) for c in b)
    lim = COORD_LIMIT_PX * ONE
    for u, v in ((0, 0), (0, W - 1), (H - 1, 0), (H - 1, W - 1)):
        X = b11 * u + b12 * v + b13
        Y = b21 * u + b22 * v + b23
        if abs(X) > lim or abs(Y) > lim:
            raise ValueError(
                f"D4: output corner (u,v)=({u},{v}) maps to source (x,y)=({X / ONE:.3f},{Y / ONE:.3f}), "
                f"outside +/-{COORD_LIMIT_PX} px")


# ---------------------------------------------------------------------------
# Coordinates
# ---------------------------------------------------------------------------

def wrap32(a):
    """Wrap integers (python int or int64 array) to signed 32-bit two's complement."""
    if isinstance(a, np.ndarray):
        a = a.astype(np.int64)
        return (((a + (1 << 31)) & 0xFFFFFFFF) - (1 << 31)).astype(np.int32)
    return ((int(a) + (1 << 31)) & 0xFFFFFFFF) - (1 << 31)


def _coords_uv(b, u, v):
    """X, Y for arrays of u, v by direct multiply-add, wrapped to int32."""
    b11, b12, b13, b21, b22, b23 = (np.int64(int(c)) for c in b)
    u = np.asarray(u, dtype=np.int64)
    v = np.asarray(v, dtype=np.int64)
    return wrap32(b11 * u + b12 * v + b13), wrap32(b21 * u + b22 * v + b23)


def coords(b, W, H):
    """Source coordinates for every output pixel, int32 arrays of shape (H, W)."""
    u, v = np.meshgrid(np.arange(H, dtype=np.int64), np.arange(W, dtype=np.int64), indexing="ij")
    return _coords_uv(b, u, v)


def coords_blocked(b, W, H, block_len, block_rows=None):
    """Coordinates as the hardware generates them.

    The frame is cut into blocks of block_rows x block_len output pixels (block_rows defaults to H,
    i.e. column strips). Each block start (X0, Y0) is computed by multiply-add; inside a block,
    +(b12, b22) per output column and +(b11, b21) per output row, all in wrapping int32 adds.
    Returns int32 arrays (H, W) that must equal coords() for every block size.
    """
    if block_len < 1:
        raise ValueError("block_len must be >= 1")
    if block_rows is None:
        block_rows = H
    if block_rows < 1:
        raise ValueError("block_rows must be >= 1")
    b11, b12, b13, b21, b22, b23 = (int(c) for c in b)
    nbc = -(-W // block_len)
    nbr = -(-H // block_rows)
    Wp, Hp = nbc * block_len, nbr * block_rows
    X = np.empty((Hp, Wp), dtype=np.int32)
    Y = np.empty((Hp, Wp), dtype=np.int32)
    # Block starts by multiply-add (shape nbr x nbc).
    ub, vb = np.meshgrid(np.arange(nbr, dtype=np.int64) * block_rows,
                         np.arange(nbc, dtype=np.int64) * block_len, indexing="ij")
    X0, Y0 = _coords_uv(b, ub, vb)
    d_row_x, d_row_y = np.int32(wrap32(b11)), np.int32(wrap32(b21))
    d_col_x, d_col_y = np.int32(wrap32(b12)), np.int32(wrap32(b22))
    Xv = X.reshape(nbr, block_rows, nbc, block_len)
    Yv = Y.reshape(nbr, block_rows, nbc, block_len)
    with np.errstate(over="ignore"):
        rx, ry = X0.copy(), Y0.copy()            # row start inside each block
        for r in range(block_rows):
            cx, cy = rx.copy(), ry.copy()
            for k in range(block_len):
                Xv[:, r, :, k] = cx
                Yv[:, r, :, k] = cy
                cx = cx + d_col_x
                cy = cy + d_col_y
            rx = rx + d_row_x
            ry = ry + d_row_y
    return X[:H, :W].copy(), Y[:H, :W].copy()


# ---------------------------------------------------------------------------
# Interpolation (D1 + D10), vectorised
# ---------------------------------------------------------------------------

def _interp(src, W, H, X, Y):
    """All per-pixel intermediate values for coordinate arrays X, Y (int32). Returns a dict."""
    X = X.astype(np.int64)
    Y = Y.astype(np.int64)
    valid = (X >= 0) & (X <= (H - 1) * ONE) & (Y >= 0) & (Y <= (W - 1) * ONE)
    x0 = X >> FRAC_BITS                       # arithmetic shift = floor
    y0 = Y >> FRAC_BITS
    xf = X & FRAC_MASK                        # low 16 bits, unsigned
    yf = Y & FRAC_MASK
    # Gather indices: only meaningful where valid; elsewhere use 0 (output is forced to 0).
    gx0 = np.where(valid, x0, 0)
    gy0 = np.where(valid, y0, 0)
    gx1 = np.minimum(gx0 + 1, H - 1)          # D1 clamp (fraction is 0 when the clamp is active)
    gy1 = np.minimum(gy0 + 1, W - 1)
    s = src.astype(np.int64)
    r1 = np.where(valid, s[gx0, gy0], 0)
    r2 = np.where(valid, s[gx0, gy1], 0)
    r3 = np.where(valid, s[gx1, gy0], 0)
    r4 = np.where(valid, s[gx1, gy1], 0)
    # D10 weights
    w2 = ((ONE - xf) * yf) >> FRAC_BITS
    w3 = (xf * (ONE - yf)) >> FRAC_BITS
    w4 = (xf * yf) >> FRAC_BITS
    w1 = ONE - (w2 + w3 + w4)
    acc = w1 * r1 + w2 * r2 + w3 * r3 + w4 * r4
    D = np.where(valid, acc >> FRAC_BITS, 0)
    return dict(X=X, Y=Y, x0=x0, y0=y0, xf=xf, yf=yf, r1=r1, r2=r2, r3=r3, r4=r4,
                w1=w1, w2=w2, w3=w3, w4=w4, valid=valid, D=D)


def _check_src(src, W, H):
    src = np.asarray(src)
    if src.shape != (H, W):
        raise ValueError(f"source shape {src.shape} does not match H x W = {H} x {W}")
    if src.dtype != np.uint8:
        raise ValueError("source must be uint8")
    return src


def warp_gray(src, W, H, b, check=True):
    """Warp a uint8 (H, W) image with integer inverse coefficients b. Returns uint8 (H, W)."""
    src = _check_src(src, W, H)
    if check:
        check_size(W, H, "gray")
        check_transform(b, W, H)
    X, Y = coords(b, W, H)
    D = _interp(src, W, H, X, Y)["D"]
    assert D.min() >= 0 and D.max() <= 255
    return D.astype(np.uint8)


# ---------------------------------------------------------------------------
# Scalar cross-check implementation (plain Python, written separately on purpose)
# ---------------------------------------------------------------------------

def _s32(n):
    n &= 0xFFFFFFFF
    return n - 0x100000000 if n & 0x80000000 else n


def warp_gray_scalar_pixel(src, W, H, b, u, v):
    """One output pixel with plain Python ints. src indexable as src[row][col]."""
    b11, b12, b13, b21, b22, b23 = (int(c) for c in b)
    X = _s32(b11 * u + b12 * v + b13)
    Y = _s32(b21 * u + b22 * v + b23)
    if X < 0 or Y < 0 or X > (H - 1) * 65536 or Y > (W - 1) * 65536:
        return 0
    x0 = X // 65536
    y0 = Y // 65536
    xf = X - x0 * 65536
    yf = Y - y0 * 65536
    x1 = x0 + 1 if x0 + 1 <= H - 1 else H - 1
    y1 = y0 + 1 if y0 + 1 <= W - 1 else W - 1
    r1 = int(src[x0][y0])
    r2 = int(src[x0][y1])
    r3 = int(src[x1][y0])
    r4 = int(src[x1][y1])
    w2 = ((65536 - xf) * yf) // 65536
    w3 = (xf * (65536 - yf)) // 65536
    w4 = (xf * yf) // 65536
    w1 = 65536 - w2 - w3 - w4
    return (w1 * r1 + w2 * r2 + w3 * r3 + w4 * r4) // 65536


def warp_gray_scalar(src, W, H, b, pixels=None):
    """Plain-loop warp. pixels = iterable of (u, v) to compute (returns a list of values);
    None = whole frame (returns a uint8 (H, W) array; slow, small images only)."""
    rows = [list(map(int, r)) for r in np.asarray(src)]
    if pixels is not None:
        return [warp_gray_scalar_pixel(rows, W, H, b, u, v) for (u, v) in pixels]
    out = np.zeros((H, W), dtype=np.uint8)
    for u in range(H):
        for v in range(W):
            out[u, v] = warp_gray_scalar_pixel(rows, W, H, b, u, v)
    return out


# ---------------------------------------------------------------------------
# Stream dump for RTL testbenches
# ---------------------------------------------------------------------------

DUMP_FIELDS = ("u", "v", "X", "Y", "x0", "y0", "xf", "yf", "r1", "r2", "r3", "r4",
               "w1", "w2", "w3", "w4", "valid", "D")


def dump_stream(path, src, W, H, b, region=None):
    """Write per-pixel intermediates for a region to an .npz file.

    region = (u0, v0, rows, cols) in output coordinates; None = whole frame.
    Each field is a flat int64 array in raster order (u outer, v inner).
    For invalid pixels (valid = 0): D = 0 and r1..r4 = 0 (no fetch); X, Y, x0, y0, xf, yf and
    w1..w4 are still the values the datapath computes.
    Also stores b, W, H and region. Returns the dict that was written.
    """
    src = _check_src(src, W, H)
    if region is None:
        region = (0, 0, H, W)
    u0, v0, nr, nc = region
    if u0 < 0 or v0 < 0 or nr < 1 or nc < 1 or u0 + nr > H or v0 + nc > W:
        raise ValueError(f"region {region} outside the {W}x{H} (W x H) output")
    u, v = np.meshgrid(np.arange(u0, u0 + nr, dtype=np.int64),
                       np.arange(v0, v0 + nc, dtype=np.int64), indexing="ij")
    X, Y = _coords_uv(b, u, v)
    d = _interp(src, W, H, X, Y)
    d["u"], d["v"] = u, v
    out = {k: np.asarray(d[k]).astype(np.int64).ravel() for k in DUMP_FIELDS}
    np.savez(path, b=np.array(b, dtype=np.int64), W=W, H=H,
             region=np.array(region, dtype=np.int64), **out)
    return out


# ---------------------------------------------------------------------------
# Independent float reference
# ---------------------------------------------------------------------------

def float_reference(src, W, H, b_float):
    """float64 bilinear warp with the same D1 rule. b_float in pixel units. Returns float64 (H, W)
    (not truncated; out-of-range pixels are 0.0)."""
    src = np.asarray(src, dtype=np.float64)
    b11, b12, b13, b21, b22, b23 = (float(c) for c in b_float)
    u, v = np.meshgrid(np.arange(H, dtype=np.float64), np.arange(W, dtype=np.float64), indexing="ij")
    x = b11 * u + b12 * v + b13
    y = b21 * u + b22 * v + b23
    valid = (x >= 0) & (x <= H - 1) & (y >= 0) & (y <= W - 1)
    xs = np.where(valid, x, 0.0)
    ys = np.where(valid, y, 0.0)
    i0 = np.floor(xs).astype(np.int64)
    j0 = np.floor(ys).astype(np.int64)
    a = xs - i0
    c = ys - j0
    i1 = np.minimum(i0 + 1, H - 1)
    j1 = np.minimum(j0 + 1, W - 1)
    val = ((1 - a) * (1 - c) * src[i0, j0] + (1 - a) * c * src[i0, j1]
           + a * (1 - c) * src[i1, j0] + a * c * src[i1, j1])
    return np.where(valid, val, 0.0)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _main(argv=None):
    p = argparse.ArgumentParser(
        prog="python -m model.patrm",
        description="Warp a raw GRAY8 image (row-major, no header) with the fixed-point PATRM model.")
    p.add_argument("--in", dest="inp", required=True, help="input raw GRAY8 file")
    p.add_argument("--out", required=True, help="output raw GRAY8 file")
    p.add_argument("--w", type=int, required=True, help="width W (pixels)")
    p.add_argument("--h", type=int, required=True, help="height H (pixels)")
    p.add_argument("--rot", type=float, default=0.0, help="forward rotation in degrees, + = counter-clockwise")
    p.add_argument("--scale", type=float, nargs="+", default=[1.0], metavar="S",
                   help="forward scale: one value, or two values sx (rows) sy (columns)")
    p.add_argument("--shift", type=float, nargs=2, default=[0.0, 0.0], metavar=("ROWS", "COLS"),
                   help="forward shift in pixels (rows, columns)")
    p.add_argument("--mirror", choices=("none", "rows", "cols", "both"), default="none")
    p.add_argument("--origin", action="store_true", help="rotate/scale/mirror about (0,0) instead of the centre")
    a = p.parse_args(argv)
    W, H = a.w, a.h
    try:
        check_size(W, H, "gray")
        if len(a.scale) not in (1, 2):
            raise ValueError("--scale takes one or two values")
        sx, sy = (a.scale[0], a.scale[0]) if len(a.scale) == 1 else a.scale
        b = make_b(W, H, rot_deg=a.rot, sx=sx, sy=sy, shift=tuple(a.shift),
                   mirror_rows=a.mirror in ("rows", "both"), mirror_cols=a.mirror in ("cols", "both"),
                   about="origin" if a.origin else "centre")
        check_transform(b, W, H)
        data = np.fromfile(a.inp, dtype=np.uint8)
        if data.size != W * H:
            raise ValueError(f"{a.inp} has {data.size} bytes, expected W*H = {W}*{H} = {W * H}")
        out = warp_gray(data.reshape(H, W), W, H, b)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    out.tofile(a.out)
    print("b =", ", ".join(str(c) for c in b))
    return 0


if __name__ == "__main__":
    sys.exit(_main())
