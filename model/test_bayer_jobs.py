"""Offline step 5.3 board-runner checks, with synthetic result records (no board)."""
import argparse
import contextlib
import io
import sys
from pathlib import Path

from model import bayer as B, job as J, patrm as P

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts/board'))
import run_job as RJ
import run_frame as RF

def main():
    checks=0
    for mode,img in (('gray','mixed'),('bayer_a','chart')):
        for transform in ('identity','rot15','rot37','rot90','mirror_cols'):
            a=argparse.Namespace(image=img,transform=transform,W=64,H=64,mode=mode,n=2,timeout_ms=1000,
                                 poll=False,sw=False,elf='offline.elf',bit='offline.bit',init='offline.tcl')
            f=RJ.prepare(a)
            desc=J.decode_job(f['descriptor']); assert desc['mode']==J.MODES[mode]
            assert f['bytes_wr']==64*64*(2 if mode=='bayer_a' else 1)
            assert 'set job(desc_words)' in f['job_file'].read_text()
            src=RF.np.frombuffer(f['src_bytes'],dtype=RF.np.uint8).reshape(64,64)
            expected=P.warp_gray(src,64,64,f['b']) if mode=='gray' else B.warp_bayer(src,64,64,f['b'])
            assert (f['expected']==expected).all()
            output=expected.tobytes()+bytes([RF.FILL_BYTE])*RF.GUARD_BYTES
            f['out_file'].write_bytes(output)
            values=dict(seq=1,rc=0,flags=J.JOB_FLAG_IRQ_EN,build_id=f['build_id'],status=R_DONE,runs=2,
                        irq_count=2,bytes_rd=f['bytes_rd'],bytes_wr=f['bytes_wr'],cycles=100,cycles_avg=100,
                        engine_ns_avg=1000,total_ns_avg=2000,timer_hz=325000000)
            def report():
                f['result_file'].write_bytes(J.encode_result(**values))
                with contextlib.redirect_stdout(io.StringIO()): return RJ.report(f,1)
            assert not report(), (mode,transform)
            values['build_id']=0x00401001 if mode=='bayer_a' else 0x00403101
            assert bool(report())==(mode=='bayer_a')
            values['build_id']=f['build_id']
            values['bytes_wr']-=8; assert report(); values['bytes_wr']+=8
            bad=bytearray(output); bad[64*64-1]^=1; f['out_file'].write_bytes(bad); assert report()
            bad=bytearray(output); bad[-1]^=1; f['out_file'].write_bytes(bad); assert report()
            checks+=1
    a.sw=True; a.mode='bayer_a'
    try: RJ.prepare(a)
    except J.JobError: pass
    else: raise AssertionError('Bayer software baseline was accepted')
    print(f'{checks} gray/Bayer jobs: model output, descriptors, build IDs, bus byte counts, last-row/guard fault detection PASS')
    print('TEST PASS')
    return 0

R_DONE=RF.R.pack('STATUS',DONE=1)
if __name__=='__main__':
    try: sys.exit(main())
    except (AssertionError,ValueError,OSError) as e:
        print('TEST FAIL:',repr(e)); sys.exit(1)
