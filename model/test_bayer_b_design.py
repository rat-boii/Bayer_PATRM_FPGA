"""Run from the repository root with python -m model.test_bayer_b_design."""
import numpy as np

from model import bayer, bayer_a, bayer_b_design as design, memmodel as mm, patrm as p
from model.gen_transforms import load


def expected_traffic(width, height, b, ps, blocks, src):
    """Independent read-count oracle using direct per-plane coordinates and absolute bus words."""
    coords = {plane: p.coords(coeff, width//2, height//2)
              for plane, coeff in bayer.plane_b(b).items()}
    previous = []
    beats = bursts = fallback = 0

    def count(intervals):
        nonlocal previous, beats, bursts
        for start, end in intervals:
            if any(a <= start and end <= z for a, z in previous):
                continue
            beats += (end - start)//8
            bursts += int(mm.burst_count(start, end))
        if intervals:
            previous = intervals

    bounds = design.rectangular_windows(ps, blocks)
    for i, (start, size) in enumerate(zip(blocks['start'], blocks['n'])):
        lo, hi, left, right = bounds.get(i,(0,0,0,0))
        if hi-lo <= design.MAX_ROWS and right-left <= mm.SPAN_MAX:
            count([(src+r*width+left, src+r*width+right) for r in range(lo,hi)])
            continue
        fallback += int(size)
        for index in range(int(start),int(start+size)):
            u,v = divmod(index,width//2)
            row_words = {}
            for lane,(dr,dc) in bayer.OFFSETS.items():
                x,y = (int(grid[u,v]) for grid in coords[lane])
                if 0 <= x <= (height//2-1)*p.ONE and 0 <= y <= (width//2-1)*p.ONE:
                    for r in (x//p.ONE,min(x//p.ONE+1,height//2-1)):
                        words = row_words.setdefault(2*r+dr,set())
                        for c in (y//p.ONE,min(y//p.ONE+1,width//2-1)):
                            words.add((2*c+dc)//8)
            intervals = []
            for row,words in row_words.items():
                for first in sorted(w for w in words if w-1 not in words):
                    end = first+1
                    while end in words:
                        end += 1
                    base = src+row*width
                    intervals.append((base+8*first,base+8*end))
            count(intervals)
    return fallback, beats, bursts


def frame(name, width, height, b, length, seed, src=mm.SRC_ADDR, dst=mm.DST_ADDR):
    raw = np.random.default_rng(seed).integers(0, 256, (height, width), dtype=np.uint8)
    actual, reader, writer = design.run(raw, b, length, src, dst)
    a, _ = bayer_a.run_job(raw, width, height, b, length)
    golden = bayer.warp_bayer(raw, width, height, b)
    assert np.array_equal(actual, golden) and np.array_equal(actual, a), name
    assert writer.written == width*height
    wr = mm.write_stats('B', width, height, dst)
    assert writer.bursts == wr['write_bursts']
    ps = mm.build_passes('B', width, height, b)[0]
    blocks = mm.make_blocks(ps, length)
    ref = mm.pass_reads(ps, blocks, width, 'P1', src)
    if name in ('tall footprint', 'wide footprint'):
        assert reader.fallback_tiles > 0
        assert (reader.fallback_tiles, reader.read_beats, reader.read_bursts) == expected_traffic(
            width, height, b, ps, blocks, src)
        print(f'{name}: {reader.fallback_tiles}/{width*height//4} fallback tiles, '
              f'{reader.read_beats} read beats, {reader.read_bursts} bursts')
    else:
        assert reader.fallback_tiles == 0, name
        assert (reader.read_beats, reader.read_bursts) == (ref['beats'], ref['bursts']), name
    return actual.size


def worked_example():
    b = (52429, -39321, 131071, 39322, 52429, 65535)
    shifts = bayer.plane_shifts(b)
    expected = bayer.plane_b(b)
    blocks = {'start': [3*32 + 2], 'n': [2], 'Wo': 32}
    tiles = next(design.coordinate_groups(b, blocks, shifts))
    assert shifts['Gr'][0] - shifts['R'][0] == -19660
    assert b[1] >> 1 == -19661
    for k, tile in enumerate(tiles):
        for plane, (x, y) in zip(bayer.PLANES, tile):
            a, c = p.coords(expected[plane], 32, 32)
            assert (x, y) == (int(a[3, 2+k]), int(c[3, 2+k]))
            if k == 0:
                print(plane, 'coordinate', (x,y), 'integer', (x>>16,y>>16),
                      'fraction', (x&65535,y&65535))


def bounds_examples():
    for width, height, matrix, expected in [
        (64,64,(7,0,0,0,1,0),(10,8)),
        (64,128,(65,0,0,0,1,0),(68,8)),
        (2048,2,(1,0,0,1024,1,0),(2,1032)),
    ]:
        ps = mm.build_passes('B', width, height, p.quantise_b(matrix))[0]
        for length in (1,64):
            blocks = mm.make_blocks(ps, length)
            r0,r1,c0,c1 = design.rectangular_windows(ps, blocks)[0]
            assert r1-r0 == expected[0]
            if length == 1 or expected[1] > 512:
                assert c1-c0 == expected[1]
        print(f'{width}x{height} first tile: {expected[0]} physical rows, {expected[1]} bytes per row')



def lockstep_check():
    """Four D10 valid pipelines driven by a common valid and ready, with a midstream reset."""
    rng = np.random.default_rng(601)
    lanes = [[None] * 4 for _ in range(4)]
    pending = []
    sent = received = stalls = 0
    for cycle in range(384):
        if cycle in (0, 127):
            lanes = [[None] * 4 for _ in range(4)]
            pending.clear()
            continue
        ready = cycle >= 320 or rng.random() > .4
        valid = cycle < 320 and rng.random() > .2
        outputs = [lane[-1] for lane in lanes]
        assert all((value is None) == (outputs[0] is None) for value in outputs)
        if outputs[0] is not None and not ready:
            stalls += 1
            continue
        if outputs[0] is not None:
            assert outputs == pending.pop(0)
            received += 1
        tile = [4*sent+k for k in range(4)] if valid else [None]*4
        if valid:
            pending.append(tile)
            sent += 1
        for lane, value in zip(lanes, tile):
            lane[:] = [value] + lane[:-1]
    assert stalls and received and not pending and all(lane == [None]*4 for lane in lanes)
    print(f'Lockstep handshake model: {stalls} stalled cycles, ordered drain after restart')


def main():
    lockstep_check()
    worked_example()
    bounds_examples()
    cases = []
    for w,h in [(64,64),(128,96)]:
        for i,tf in enumerate(load()):
            cases.append((tf['name'], w,h, mm._b_for(tf,w,h), [1,7,64][i%3]))
    for w,h,b in [(16,2,(1,0,0,0,1,0)), (4096,2,(1,0,0,0,1,0)),
                  (16,4096,(1,0,0,0,1,0)), (64,64,(7,0,0,0,1,0)),
                  (64,64,(1,0,-200,0,1,-200))]:
        cases.append(('directed',w,h,p.quantise_b(b),64))
    cases.append(('odd rounding',64,64,(52429,-39321,131071,39322,52429,65535),16))
    for i in range(12):
        rng = np.random.default_rng(211+i)
        b = p.make_b(64,64, rot_deg=rng.uniform(-180,180), sx=rng.uniform(.55,1.8),
                     sy=rng.uniform(.55,1.8), shift=tuple(rng.uniform(-11,11,2)))
        cases.append(('seeded',64,64,b,[1,7,64][i%3]))
    cases.extend([
        ('tall footprint',64,128,p.quantise_b((65,0,0,0,1,0)),64),
        ('wide footprint',2048,2,p.quantise_b((1,0,0,1024,1,0)),64),
    ])
    total = 0
    for seed, (name,w,h,b,length) in enumerate(cases):
        total += frame(name,w,h,b,length,seed,mm.SRC_ADDR + (4088 if seed % 2 else 0),
                       mm.DST_ADDR + (4088 if seed % 2 else 0))
    print(f'{len(cases)} frames, {total:,} output bytes compared with Option A and golden')
    print('TEST PASS')


if __name__ == '__main__':
    main()
