/* ARM software baseline (step 4.4): the PATRM grayscale warp in plain C, bit-exact with model/patrm.py warp_gray.
 *
 * Same fixed-point algorithm as the engine: Q15.16 coordinates, inverse mapping x = b11*u + b12*v + b13,
 * y = b21*u + b22*v + b23 (x = row, y = column), D1 edge rule, D10 bilinear interpolator, output truncated to 8 bits.
 * Portable C99 with no Xilinx headers, so the same file builds on the laptop (gcc) and on the Cortex-A9.
 */
#ifndef PATRM_SW_H
#define PATRM_SW_H

#include <stdint.h>

#define PATRM_SW_OK        0
#define PATRM_SW_BAD_SIZE  (-1)     /* W or H outside 1..4096 (D11) or W not a multiple of 8 (D3) */

/* Warps src (H rows of W bytes, row-major GRAY8) into dst (same size) with the integer inverse coefficients
 * b = {b11, b12, b13, b21, b22, b23} (signed Q15.16, already quantised with D5). Every output pixel is written.
 * The transform is not checked here (D4: the PC tool and the driver reject it before). src and dst must not overlap. */
int patrm_sw_gray(const uint8_t *src, uint8_t *dst, uint32_t W, uint32_t H, const int32_t b[6]);

#endif
