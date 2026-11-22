/* ARM software baseline (step 4.4). Bit-exact with model/patrm.py warp_gray; see patrm_sw.h.
 *
 * Coordinates: X and Y are kept as uint32_t and stepped by addition, +(b12, b22) per output column and +(b11, b21)
 * per output row, exactly like the engine inside a block. Unsigned addition wraps mod 2^32, so the result equals the
 * model's direct multiply-add wrapped to int32 (D4: intermediate wraps cancel).
 * D1: a pixel is valid if 0 <= X <= (H-1)*65536 and 0 <= Y <= (W-1)*65536 on the signed Q15.16 value. Because
 * (H-1)*65536 < 2^31, one unsigned compare does both tests: a negative X is >= 2^31 as uint32_t.
 * Integer part = X >> 16 and fraction = X & 0xFFFF (valid X is non-negative, so this is the model's floor).
 * The next row / column index is clamped to H-1 / W-1; the fraction is 0 then, so that neighbour has weight 0.
 * D10: w2 = ((65536-xf)*yf)>>16, w3 = (xf*(65536-yf))>>16, w4 = (xf*yf)>>16, w1 = 65536-(w2+w3+w4);
 * D = (w1*r1 + w2*r2 + w3*r3 + w4*r4) >> 16. The largest product is 65536*65535 < 2^32 and the weighted sum is at
 * most 65536*255, so uint32_t holds every intermediate value.
 */
#include "patrm_sw.h"

#define FRAC_BITS 16U
#define ONE       65536U
#define FRAC_MASK 0xFFFFU
#define MAX_SIZE  4096U

int patrm_sw_gray(const uint8_t *src, uint8_t *dst, uint32_t W, uint32_t H, const int32_t b[6])
{
    const uint32_t b11 = (uint32_t)b[0], b12 = (uint32_t)b[1], b13 = (uint32_t)b[2];
    const uint32_t b21 = (uint32_t)b[3], b22 = (uint32_t)b[4], b23 = (uint32_t)b[5];
    uint32_t xmax, ymax, row_x, row_y, u, v;

    if ((W == 0U) || (H == 0U) || (W > MAX_SIZE) || (H > MAX_SIZE) || ((W % 8U) != 0U)) {
        return PATRM_SW_BAD_SIZE;
    }
    xmax = (H - 1U) << FRAC_BITS;
    ymax = (W - 1U) << FRAC_BITS;
    row_x = b13;                                   /* (u, v) = (0, 0) */
    row_y = b23;
    for (u = 0U; u < H; u++) {
        uint8_t *out = dst + (uint32_t)u * W;
        uint32_t X = row_x;
        uint32_t Y = row_y;

        for (v = 0U; v < W; v++) {
            if ((X <= xmax) && (Y <= ymax)) {
                const uint32_t x0 = X >> FRAC_BITS;
                const uint32_t y0 = Y >> FRAC_BITS;
                const uint32_t xf = X & FRAC_MASK;
                const uint32_t yf = Y & FRAC_MASK;
                const uint32_t x1 = (x0 < H - 1U) ? x0 + 1U : H - 1U;
                const uint32_t y1 = (y0 < W - 1U) ? y0 + 1U : W - 1U;
                const uint8_t *row0 = src + x0 * W;
                const uint8_t *row1 = src + x1 * W;
                const uint32_t w2 = ((ONE - xf) * yf) >> FRAC_BITS;
                const uint32_t w3 = (xf * (ONE - yf)) >> FRAC_BITS;
                const uint32_t w4 = (xf * yf) >> FRAC_BITS;
                const uint32_t w1 = ONE - (w2 + w3 + w4);

                out[v] = (uint8_t)((w1 * row0[y0] + w2 * row0[y1] + w3 * row1[y0] + w4 * row1[y1]) >> FRAC_BITS);
            } else {
                out[v] = 0U;
            }
            X += b12;
            Y += b22;
        }
        row_x += b11;
        row_y += b21;
    }
    return PATRM_SW_OK;
}
