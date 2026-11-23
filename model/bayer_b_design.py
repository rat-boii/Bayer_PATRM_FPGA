"""Executable design for step 6.1. Models B's fetch windows, four lanes and full-word writer."""
from dataclasses import dataclass

import numpy as np

from model import bayer, memmodel as mm, patrm as p

MAX_ROWS = 16
N_SLOTS = 32


@dataclass(frozen=True)
class Window:
    row: int
    start: int
    end: int

    def covers(self, other):
        return self.row == other.row and self.start <= other.start and other.end <= self.end


class Rows:
    """Replay physical reads. Only data held by the previous fetching group may be reused."""

    def __init__(self, source, base):
        self.source = source
        self.width = source.shape[1]
        self.base = base
        self.previous = {}
        self.slots = {}
        self.read_beats = 0
        self.read_bursts = 0
        self.hits = 0
        self.peak = 0
        self.fallback_tiles = 0

    def load(self, windows):
        if not windows:
            return {}
        assert len(windows) <= MAX_ROWS
        free = iter(sorted(set(range(N_SLOTS)) - set(self.previous.values())))
        current = {}
        for window in windows:
            row, start, end = window.row, window.start, window.end
            assert 0 <= row < self.source.shape[0]
            assert 0 <= start < end <= self.width and end - start <= mm.SPAN_MAX
            assert start % 8 == end % 8 == 0
            slot = next((s for old, s in self.previous.items() if old.covers(window)), None)
            if slot is None:
                slot = next(free)
                addr = self.base + row * self.width
                data = bytearray()
                for a, beats in mm.split_bursts(addr + start, addr + end):
                    assert 1 <= beats <= 16 and a // 4096 == (a + 8 * beats - 1) // 4096
                    data.extend(self.source[row, a-addr:a-addr + 8*beats].tobytes())
                    self.read_beats += beats
                    self.read_bursts += 1
                assert len(data) == end - start
                self.slots[slot] = (start, data)
            else:
                self.hits += 1
            current[window] = slot
        self.peak = max(self.peak, len(set(current.values()) | set(self.previous.values())))
        assert self.peak <= N_SLOTS
        self.previous = current
        return current

    def sample(self, current, row, col):
        for window, slot in current.items():
            if window.row == row and window.start <= col < window.end:
                origin, data = self.slots[slot]
                return data[col - origin]
        raise AssertionError(f'Unbuffered sample at {row}, {col}')


def sample_addresses(x, y, plane, width, height):
    if not (0 <= x <= (height // 2 - 1) * p.ONE and 0 <= y <= (width // 2 - 1) * p.ONE):
        return ()
    x0, y0 = x >> 16, y >> 16
    x1, y1 = min(x0 + 1, height // 2 - 1), min(y0 + 1, width // 2 - 1)
    parity_row, parity_col = bayer.OFFSETS[plane]
    return tuple((2*r + parity_row, 2*c + parity_col) for r in (x0, x1) for c in (y0, y1))


def coordinate_groups(b, blocks, shifts):
    for start, size in zip(blocks['start'], blocks['n']):
        u, v = divmod(int(start), blocks['Wo'])
        rx = p.wrap32(b[0]*u + b[1]*v + shifts['R'][0])
        ry = p.wrap32(b[3]*u + b[4]*v + shifts['R'][1])
        group = []
        for _ in range(int(size)):
            group.append([(p.wrap32(rx + tx - shifts['R'][0]), p.wrap32(ry + ty - shifts['R'][1]))
                          for tx, ty in (shifts[lane] for lane in bayer.PLANES)])
            rx, ry = p.wrap32(rx + b[1]), p.wrap32(ry + b[4])
        yield group


class Writer:
    """Gather a pair of output rows, then drain in the order expected by the HP1 writer."""

    def __init__(self, width, height, base):
        self.width, self.height, self.base = width, height, base
        self.rows = [bytearray(), bytearray()]
        self.guard = 8
        self.memory = bytearray([0xAC]) * (width*height + 2*self.guard)
        self.written = 0
        self.bursts = 0

    def accept(self, tile):
        red, gr, gb, blue = tile
        self.rows[0].extend((red, gr))
        self.rows[1].extend((gb, blue))
        if len(self.rows[0]) == self.width:
            for row in self.rows:
                addr = self.base + self.written
                for a, beats in mm.split_bursts(addr, addr + self.width):
                    assert 1 <= beats <= 16 and a // 4096 == (a + 8*beats - 1) // 4096
                    start = a - addr
                    dst = self.guard + a - self.base
                    self.memory[dst:dst + 8*beats] = row[start:start + 8*beats]
                    self.bursts += 1
                self.written += self.width
                row.clear()

    def result(self):
        assert self.written == self.width*self.height and not any(self.rows)
        sentinel = bytearray([0xAC]) * self.guard
        assert self.memory[:self.guard] == self.memory[-self.guard:] == sentinel
        return np.frombuffer(self.memory, dtype=np.uint8, count=self.written,
                             offset=self.guard).reshape(self.height, self.width)


def rectangular_windows(ps, blocks):
    first, end, _ = mm._block_geometry(ps, blocks)
    return {int(i): (2*int(lo), 2*int(hi)+2, int(s), int(e))
            for i, lo, hi, s, e in zip(blocks['ids'], blocks['rlo'], blocks['rhi'], first, end)}

def tile_windows(tile, width, height):
    """Merge neighbouring aligned words within each physical source row."""
    words = set()
    for plane, (x, y) in zip(bayer.PLANES, tile):
        for row, col in sample_addresses(x, y, plane, width, height):
            words.add((row, col - col % 8))
    windows = []
    for row, start in sorted(words):
        if windows and windows[-1].row == row and windows[-1].end == start:
            start_of_run = windows[-1].start
            windows[-1] = Window(row, start_of_run, start + 8)
        else:
            windows.append(Window(row, start, start + 8))
    return windows


def run(source, b, length=64, src=mm.SRC_ADDR, dst=mm.DST_ADDR):
    height, width = source.shape
    ps = mm.build_passes('B', width, height, b)[0]
    blocks = mm.make_blocks(ps, length)
    bounds = rectangular_windows(ps, blocks)
    memory = Rows(source, src)
    writer = Writer(width, height, dst)
    shifts = bayer.plane_shifts(b)
    for index, tiles in enumerate(coordinate_groups(b, blocks, shifts)):
        lo, hi, start, end = bounds.get(index, (0, 0, 0, 0))
        oversized = hi - lo > MAX_ROWS or end - start > mm.SPAN_MAX
        if not oversized:
            current = memory.load([Window(row, start, end) for row in range(lo, hi)])
        for tile in tiles:
            if oversized:
                current = memory.load(tile_windows(tile, width, height))
                memory.fallback_tiles += 1
            outputs = []
            for plane, (x, y) in zip(bayer.PLANES, tile):
                neighbours = sample_addresses(x, y, plane, width, height)
                if neighbours:
                    pixels = [memory.sample(current, r, c) for r, c in neighbours]
                    value = int(p.interp_d10(x & 65535, y & 65535, *pixels)[-1])
                else:
                    value = 0
                outputs.append(value)
            writer.accept(outputs)
    return writer.result(), memory, writer
