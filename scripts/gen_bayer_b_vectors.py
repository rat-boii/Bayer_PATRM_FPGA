"""Generate step 6.2 full-frame simulations and the rectangular-only comparison."""
import numpy as np

from gen_patrm_top_vectors import Gen, OUT_DIR, CASE_HEADER
from model import memmodel as MM, patrm as P
from model import bayer_b_design as design


class BayerCases(Gen):
    def b_of(self, tf, W, H):
        directed = {'wide': (1,0,0,1024,1,0), 'tall': (65,0,0,0,1,0)}
        if tf == 'odd':
            return (52429,-39321,131071,39322,52429,65535)
        if tf in directed:
            return P.quantise_b(directed[tf])
        return super().b_of(tf,W,H)

    def add_b(self, group, tf, w, h, length=64, **timing):
        self.add(group, tf, w, h, length, mode=1, **timing)
        mosaic, _ = self.src(w,h)
        reads = []
        out, reader, writer = design.run(mosaic,self.b_of(tf,w,h),length,trace=reads)
        writes = [burst for row in range(h) for burst in MM.split_bursts(
            MM.DST_ADDR+row*w,MM.DST_ADDR+(row+1)*w)]
        trace = OUT_DIR / f'b_{tf}_{w}x{h}_{length}.trace'
        trace.write_text(str(reader.fallback_tiles)+'\n'+''.join(
            f'{addr:x} {beats}\n' for addr,beats in reads+writes))
        assert np.array_equal(out,self.exps[('A',tf,w,h)][1])
        fields = self.cases[-1].split()
        columns = CASE_HEADER.split()
        for name, value in [('bytes_rd', 8*reader.read_beats), ('rd_bursts', reader.read_bursts),
                            ('wr_bursts', writer.bursts), ('mode', 2)]:
            fields[columns.index(name)] = str(value)
        self.cases[-1] = ' '.join(fields)


def main():
    OUT_DIR.mkdir(parents=True,exist_ok=True)
    g = BayerCases()
    for tf in g.tfs:
        g.add_b('h',tf,64,64,lat=(7,20),ar_bp=20,r_gap=30,aw_bp=20,w_bp=40)
    g.add_b('h','rot37',128,96,7)
    g.add_b('f','identity',256,16,w_bp=97)
    g.add_b('f','odd',64,64,1)
    g.add_b('b','identity',64,64,op=1)
    g.add_b('c','identity',64,64,op=6)
    g.add_b('d','rot15',64,64,op=2)
    g.add_b('d','identity',64,64,op=3)
    g.add_b('g','identity',64,64,op=4,arg=30)
    g.add_b('g','identity',64,64,op=4,arg=1000)
    g.add('g','identity',64,64,mode=1)
    g.add('g','rot15',64,64)
    g.add_b('g','identity',256,16,op=4,arg=-1)
    g.add_b('g','identity',256,16,op=4,arg=-2)
    g.add_b('g','identity',64,64)
    g.add_b('h','identity',4096,2)
    g.add_b('h','rot37',208,120,32,ar_bp=15,w_bp=40)
    rect = list(g.cases)
    g.add_b('h','tall',64,128)
    g.add_b('h','wide',2048,2,irq=0)
    for name,cases in [('cases_bayer_b',g.cases),('cases_b_rect',rect)]:
        (OUT_DIR/(name+'.txt')).write_text('# '+CASE_HEADER+'\n'+'\n'.join(cases)+'\n')
    print('Generated',len(g.cases),'combined-build cases')


if __name__ == '__main__':
    main()
