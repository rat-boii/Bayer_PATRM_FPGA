"""generated from spec/regs.json, do not edit.

PATRM engine register map (AXI-Lite slave on M_AXI_GP0), version 1.
Tables plus pack/unpack helpers; see scripts/gen_regs.py.
"""

VERSION = 1
ADDR_BITS = 7

# Constants
MAX_SIZE = 4096   # D11: largest WIDTH and largest HEIGHT (pixels)
SIZE_BITS = 13   # D11: width of the WIDTH / HEIGHT / BLOCK_LEN fields
GRAY_W_MULT = 8   # D3: grayscale WIDTH must be a multiple of this
BAYER_W_MULT = 16   # D3: Bayer WIDTH must be a multiple of this
BAYER_H_MULT = 2   # D3: Bayer HEIGHT must be a multiple of this
ADDR_ALIGN = 4096   # SRC_ADDR and DST_ADDR must be multiples of this (4 KB)
FRAC_BITS = 16   # Q15.16 fraction bits

# MODE: CTRL.MODE values
MODE = {'GRAY': 0, 'BAYER_A': 1, 'BAYER_B': 2}
# BUILD_TYPE: BUILD_ID.BUILD_TYPE values
BUILD_TYPE = {'GRAY': 0, 'BAYER_A': 1, 'BAYER_B': 2}
# ERR: STATUS.ERR_CODE values. If several checks fail, the code reported is the first in this order: START_BUSY, BAD_MODE, BAD_SIZE, BAD_ADDR, BAD_BLOCK_LEN.
ERR = {'NONE': 0, 'BAD_SIZE': 1, 'BAD_MODE': 2, 'BAD_ADDR': 3, 'BAD_BLOCK_LEN': 4, 'START_BUSY': 5}

# Registers in offset order. reset None = fixed per build (synthesis parameters).
REGISTERS = [
    {'name': 'CTRL', 'offset': 0x00, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'START', 'lsb': 0, 'width': 1, 'access': 'WP', 'reset': 0, 'signed': False, 'enum': None},
        {'name': 'MODE', 'lsb': 1, 'width': 2, 'access': 'RW', 'reset': 0, 'signed': False, 'enum': 'MODE'},
        {'name': 'IRQ_EN', 'lsb': 3, 'width': 1, 'access': 'RW', 'reset': 0, 'signed': False, 'enum': None},
    ]},
    {'name': 'STATUS', 'offset': 0x04, 'access': 'RO/W1C', 'reset': 0x00000000, 'fields': [
        {'name': 'BUSY', 'lsb': 0, 'width': 1, 'access': 'RO', 'reset': 0, 'signed': False, 'enum': None},
        {'name': 'DONE', 'lsb': 1, 'width': 1, 'access': 'W1C', 'reset': 0, 'signed': False, 'enum': None},
        {'name': 'ERROR', 'lsb': 2, 'width': 1, 'access': 'W1C', 'reset': 0, 'signed': False, 'enum': None},
        {'name': 'ERR_CODE', 'lsb': 4, 'width': 4, 'access': 'RO', 'reset': 0, 'signed': False, 'enum': 'ERR'},
    ]},
    {'name': 'SRC_ADDR', 'offset': 0x08, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'ADDR', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 0, 'signed': False, 'enum': None},
    ]},
    {'name': 'DST_ADDR', 'offset': 0x0C, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'ADDR', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 0, 'signed': False, 'enum': None},
    ]},
    {'name': 'WIDTH', 'offset': 0x10, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'W', 'lsb': 0, 'width': 13, 'access': 'RW', 'reset': 0, 'signed': False, 'enum': None},
    ]},
    {'name': 'HEIGHT', 'offset': 0x14, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'H', 'lsb': 0, 'width': 13, 'access': 'RW', 'reset': 0, 'signed': False, 'enum': None},
    ]},
    {'name': 'B11', 'offset': 0x18, 'access': 'RW', 'reset': 0x00010000, 'fields': [
        {'name': 'VALUE', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 65536, 'signed': True, 'enum': None},
    ]},
    {'name': 'B12', 'offset': 0x1C, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'VALUE', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 0, 'signed': True, 'enum': None},
    ]},
    {'name': 'B13', 'offset': 0x20, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'VALUE', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 0, 'signed': True, 'enum': None},
    ]},
    {'name': 'B21', 'offset': 0x24, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'VALUE', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 0, 'signed': True, 'enum': None},
    ]},
    {'name': 'B22', 'offset': 0x28, 'access': 'RW', 'reset': 0x00010000, 'fields': [
        {'name': 'VALUE', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 65536, 'signed': True, 'enum': None},
    ]},
    {'name': 'B23', 'offset': 0x2C, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'VALUE', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 0, 'signed': True, 'enum': None},
    ]},
    {'name': 'T_R_X', 'offset': 0x30, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'VALUE', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 0, 'signed': True, 'enum': None},
    ]},
    {'name': 'T_R_Y', 'offset': 0x34, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'VALUE', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 0, 'signed': True, 'enum': None},
    ]},
    {'name': 'T_GR_X', 'offset': 0x38, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'VALUE', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 0, 'signed': True, 'enum': None},
    ]},
    {'name': 'T_GR_Y', 'offset': 0x3C, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'VALUE', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 0, 'signed': True, 'enum': None},
    ]},
    {'name': 'T_GB_X', 'offset': 0x40, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'VALUE', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 0, 'signed': True, 'enum': None},
    ]},
    {'name': 'T_GB_Y', 'offset': 0x44, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'VALUE', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 0, 'signed': True, 'enum': None},
    ]},
    {'name': 'T_B_X', 'offset': 0x48, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'VALUE', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 0, 'signed': True, 'enum': None},
    ]},
    {'name': 'T_B_Y', 'offset': 0x4C, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'VALUE', 'lsb': 0, 'width': 32, 'access': 'RW', 'reset': 0, 'signed': True, 'enum': None},
    ]},
    {'name': 'BLOCK_LEN', 'offset': 0x50, 'access': 'RW', 'reset': 0x00000000, 'fields': [
        {'name': 'L', 'lsb': 0, 'width': 13, 'access': 'RW', 'reset': 0, 'signed': False, 'enum': None},
    ]},
    {'name': 'CYCLES', 'offset': 0x54, 'access': 'RO', 'reset': 0x00000000, 'fields': [
        {'name': 'COUNT', 'lsb': 0, 'width': 32, 'access': 'RO', 'reset': 0, 'signed': False, 'enum': None},
    ]},
    {'name': 'BYTES_RD', 'offset': 0x58, 'access': 'RO', 'reset': 0x00000000, 'fields': [
        {'name': 'COUNT', 'lsb': 0, 'width': 32, 'access': 'RO', 'reset': 0, 'signed': False, 'enum': None},
    ]},
    {'name': 'BYTES_WR', 'offset': 0x5C, 'access': 'RO', 'reset': 0x00000000, 'fields': [
        {'name': 'COUNT', 'lsb': 0, 'width': 32, 'access': 'RO', 'reset': 0, 'signed': False, 'enum': None},
    ]},
    {'name': 'RD_STALL', 'offset': 0x60, 'access': 'RO', 'reset': 0x00000000, 'fields': [
        {'name': 'COUNT', 'lsb': 0, 'width': 32, 'access': 'RO', 'reset': 0, 'signed': False, 'enum': None},
    ]},
    {'name': 'WR_STALL', 'offset': 0x64, 'access': 'RO', 'reset': 0x00000000, 'fields': [
        {'name': 'COUNT', 'lsb': 0, 'width': 32, 'access': 'RO', 'reset': 0, 'signed': False, 'enum': None},
    ]},
    {'name': 'BUILD_ID', 'offset': 0x68, 'access': 'RO', 'reset': None, 'fields': [
        {'name': 'VERSION', 'lsb': 0, 'width': 8, 'access': 'RO', 'reset': None, 'signed': False, 'enum': None},
        {'name': 'BUILD_TYPE', 'lsb': 8, 'width': 2, 'access': 'RO', 'reset': None, 'signed': False, 'enum': 'BUILD_TYPE'},
        {'name': 'MODES', 'lsb': 12, 'width': 3, 'access': 'RO', 'reset': None, 'signed': False, 'enum': None},
        {'name': 'BLOCK_LEN_MAX', 'lsb': 16, 'width': 13, 'access': 'RO', 'reset': None, 'signed': False, 'enum': None},
    ]},
]

REG = {r['name']: r for r in REGISTERS}
OFFSET = {r['name']: r['offset'] for r in REGISTERS}
NAME = {r['offset']: r['name'] for r in REGISTERS}


def field(reg, name):
    for f in REG[reg]['fields']:
        if f['name'] == name:
            return f
    raise KeyError(f'{reg}.{name}')


def field_range(reg, name):
    """(lowest, highest) value the field can hold."""
    f = field(reg, name)
    if f['signed']:
        return -(1 << (f['width'] - 1)), (1 << (f['width'] - 1)) - 1
    return 0, (1 << f['width']) - 1


def pack(reg, **values):
    """32-bit register value from field values; raises ValueError if a value does not fit.
    Fields not given are 0."""
    names = {f['name'] for f in REG[reg]['fields']}
    word = 0
    for name, v in values.items():
        if name not in names:
            raise ValueError(f'{reg} has no field {name}')
        f = field(reg, name)
        lo, hi = field_range(reg, name)
        if not isinstance(v, int) or not lo <= v <= hi:
            raise ValueError(f'{reg}.{name} = {v} does not fit {f["width"]} '
                             f'{"signed" if f["signed"] else "unsigned"} bits ({lo}..{hi})')
        word |= (v & ((1 << f['width']) - 1)) << f['lsb']
    return word


def unpack(reg, word):
    """Field values from a 32-bit register value (signed fields sign-extended)."""
    out = {}
    for f in REG[reg]['fields']:
        v = (word >> f['lsb']) & ((1 << f['width']) - 1)
        if f['signed'] and v >> (f['width'] - 1):
            v -= 1 << f['width']
        out[f['name']] = v
    return out
