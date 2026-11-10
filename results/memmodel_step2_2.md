# Memory schedule, step 2.2 (exact hardware rules)

Rules: D14 (P1 row reuse), D15 (BLOCK_LEN_MAX 64, driver default 64), D16 (block ends at x0 change, BLOCK_LEN, or SPAN_MAX = 512 bytes); exact definitions in the docstring of `model/memmodel.py` and in `spec/interface.md`. **All speeds are ESTIMATES** (same formula as step 1.4: cycles = max(pixels, read beats + 2 x read bursts) at 100 MHz, latency assumed hidden). Full data: `memmodel_step2_2.csv`.

## Comparison with step 1.4 (grayscale, all sizes, Lmax 16/32/64, P0 and P1)

162 of 162 rows identical to `memmodel_step1_4.csv` in blocks, bursts, beats, bytes_read, est_cycles, est_fps, max_footprint.
Reason: rule (c) never fires for the nine test transforms (largest block span at 2448x2095 is far below 512 bytes), and rules (a), (b) and P1 are the step 1.4 rules, now written down exactly.

## Grayscale 2448x2095, P1, BLOCK_LEN 64 (D15): the configuration we build

| transform | blocks | bursts | amp | mean burst (beats) | fps (est) | read MB/s (est) | max span (B) | max footprint (B) |
|---|---|---|---|---|---|---|---|---|
| identity | 81705 | 165859 | 2.25 | 8.69 | 19.5 | 225 | 72 | 144 |
| mirror_cols | 81705 | 165859 | 2.25 | 8.69 | 19.5 | 225 | 72 | 144 |
| mirror_rows | 81705 | 165859 | 2.25 | 8.69 | 19.5 | 225 | 72 | 144 |
| rot5 | 432961 | 862574 | 3.25 | 2.42 | 19.5 | 325 | 24 | 48 |
| rot15 | 1199094 | 1750395 | 4.47 | 1.64 | 15.7 | 360 | 16 | 32 |
| rot37 | 2567908 | 2982192 | 6.07 | 1.30 | 10.1 | 316 | 16 | 32 |
| scale0p8 | 81705 | 109189 | 1.76 | 10.34 | 19.5 | 176 | 88 | 176 |
| scale1p25 | 81705 | 165411 | 1.91 | 7.40 | 19.5 | 191 | 64 | 128 |
| combined | 809838 | 1361311 | 3.84 | 1.81 | 19.3 | 380 | 16 | 32 |

## Grayscale, all sizes, P1: estimated fps (Lmax 16 / 32 / 64), unchanged from step 1.4

| transform | 640x480 | 1920x1080 | 2448x2095 |
|---|---|---|---|
| identity | 326 / 326 / 326 | 48 / 48 / 48 | 19 / 19 / 19 |
| mirror_cols | 326 / 326 / 326 | 48 / 48 / 48 | 19 / 19 / 19 |
| mirror_rows | 326 / 326 / 326 | 48 / 48 / 48 | 19 / 19 / 19 |
| rot5 | 326 / 326 / 326 | 48 / 48 / 48 | 19 / 19 / 19 |
| rot15 | 263 / 263 / 263 | 40 / 40 / 40 | 16 / 16 / 16 |
| rot37 | 172 / 172 / 172 | 27 / 27 / 27 | 10 / 10 / 10 |
| scale0p8 | 326 / 326 / 326 | 48 / 48 / 48 | 19 / 19 / 19 |
| scale1p25 | 326 / 326 / 326 | 48 / 48 / 48 | 19 / 19 / 19 |
| combined | 324 / 324 / 324 | 48 / 48 / 48 | 19 / 19 / 19 |

## Extreme zoom-out (rule (c) at work), BLOCK_LEN 64, P1

Every D4-valid transform is supported: rule (c) caps every block at 512 bytes per row, so a gray or Bayer A block never needs more than 2 x 512 bytes of buffer. Here the estimate stays at the compute bound (1 pixel per clock): most output pixels of a zoom-out fall outside the source and need no data, and the valid ones read long bursts; rule (c) only splits the blocks that would be too wide. Speed falls only where blocks become very short (large rotations, see the table above).

| transform | mode | size | blocks | end: row | end: x0 | end: len | end: span | max span (B) | max footprint (B) | amp | fps (est) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| scale0p1 | gray | 2448x2095 | 81705 | 2095 | 0 | 78983 | 627 | 512 | 1024 | 0.20 | 19.5 |
| scale0p1 | A | 2448x2048 | 82328 | 4096 | 0 | 77008 | 1224 | 512 | 1024 | 0.39 | 19.9 |
| scale0p25 | gray | 2448x2095 | 81705 | 2095 | 0 | 79610 | 0 | 256 | 512 | 0.50 | 19.5 |
| scale0p25 | A | 2448x2048 | 81920 | 4096 | 0 | 77824 | 0 | 512 | 1024 | 1.00 | 19.9 |
| cols0p1 | gray | 2448x2095 | 81705 | 2095 | 0 | 73325 | 6285 | 512 | 1024 | 1.97 | 19.5 |
| cols0p1 | A | 2448x2048 | 86016 | 4096 | 0 | 69632 | 12288 | 512 | 1024 | 3.91 | 19.9 |
| rot30_scale0p2 | gray | 2448x2095 | 282424 | 2095 | 204355 | 75974 | 0 | 16 | 32 | 0.72 | 19.5 |
| rot30_scale0p2 | A | 2448x2048 | 276820 | 4096 | 198984 | 73740 | 0 | 16 | 32 | 0.80 | 19.9 |

## On-chip buffer

NSLOT = 32 row slots x SPAN_MAX = 512 bytes = 16 KB (gray and Bayer A need at most 2 slots per block; see spec/interface.md for the RAM organisation).

