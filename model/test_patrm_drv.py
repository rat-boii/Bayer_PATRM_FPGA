"""Step 5.3 offline driver check: compile the actual C driver with mocked BSP I/O.

Compares validation and every configuration write with model/job.py, including negative
odd D2 sums, overflow, full/plane D4 checks and gray/A capability checks. No board access.
The mocks do not verify interrupts, real caches, DDR or hardware execution.
"""
import random
import shutil
import subprocess
import sys
from pathlib import Path

from model import patrm as P, job as J
from model.gen_transforms import load

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build' / 'test_patrm_drv'
BSP = r"""
#ifndef BSP_MOCK_H
#define BSP_MOCK_H
#include <stdint.h>
#include <stddef.h>
typedef intptr_t INTPTR;
typedef uint64_t XTime;
typedef struct { uint32_t dummy; } XScuGic;
typedef struct { uint32_t CpuBaseAddress; } XScuGic_Config;
typedef void (*Xil_ExceptionHandler)(void *);
static uint32_t mock_addr[64], mock_value[64], mock_count;
static inline uint32_t Xil_In32(uint32_t a) { (void)a; return 0; }
static inline void Xil_Out32(uint32_t a, uint32_t v) { mock_addr[mock_count]=a; mock_value[mock_count++]=v; }
static inline void XTime_GetTime(XTime *v) { *v=1; }
static inline void Xil_DCacheFlushRange(INTPTR a, INTPTR n) { (void)a; (void)n; }
static inline void Xil_DCacheInvalidateRange(INTPTR a, INTPTR n) { (void)a; (void)n; }
static inline XScuGic_Config *XScuGic_LookupConfig(uint32_t a) { (void)a; return NULL; }
static inline int XScuGic_CfgInitialize(XScuGic *g, XScuGic_Config *c, uint32_t a) { (void)g;(void)c;(void)a;return 0; }
static inline void Xil_ExceptionInit(void) {}
static inline void Xil_ExceptionRegisterHandler(int n, Xil_ExceptionHandler h, void *g) {(void)n;(void)h;(void)g;}
static inline void Xil_ExceptionEnable(void) {}
static inline void XScuGic_InterruptHandler(void *g) {(void)g;}
static inline void XScuGic_SetPriorityTriggerType(XScuGic *g,uint32_t n,uint32_t p,uint32_t t) {(void)g;(void)n;(void)p;(void)t;}
static inline int XScuGic_Connect(XScuGic *g,uint32_t n,Xil_ExceptionHandler h,void *d) {(void)g;(void)n;(void)h;(void)d;return 0;}
static inline void XScuGic_Enable(XScuGic *g,uint32_t n) {(void)g;(void)n;}
static inline uint32_t XScuGic_DistReadReg(XScuGic *g,uint32_t o) {(void)g;(void)o;return 0;}
static inline void dsb(void) {}
#define COUNTS_PER_SECOND 325000000U
#define XPAR_XSCUGIC_0_BASEADDR 0U
#define XST_SUCCESS 0
#define XIL_EXCEPTION_ID_IRQ_INT 0
#define XSCUGIC_ENABLE_SET_OFFSET 0U
#define XSCUGIC_PENDING_SET_OFFSET 0U
#define XSCUGIC_EN_DIS_OFFSET_CALC(o,n) ((o)+(n))
#define XSCUGIC_INT_CFG_OFFSET_CALC(n) (n)
#define XSCUGIC_PRIORITY_OFFSET_CALC(n) (n)
#endif
"""
HARNESS = r"""
#include <stdio.h>
#include <inttypes.h>
#include "patrm_drv.c"
int main(void) {
    int64_t v[14]; unsigned i;
    while (scanf("%" SCNd64, &v[0]) == 1) {
        patrm_job_t job = {0}; patrm_dev_t dev = {0}; patrm_rc_t rc;
        for (i=1;i<14;i++) if(scanf("%" SCNd64,&v[i])!=1) return 2;
        job.mode=(uint32_t)v[0]; job.width=(uint32_t)v[1]; job.height=(uint32_t)v[2];
        job.block_len=(uint32_t)v[3]; job.src_addr=(uint32_t)v[4]; job.dst_addr=(uint32_t)v[5];
        for(i=0;i<6;i++) job.b[i]=(int32_t)v[i+6];
        dev.modes=(uint32_t)v[12]; dev.block_len_max=(uint32_t)v[13];
        dev.base=PATRM_REG_BASE; mock_count=0;
        rc=patrm_validate(&dev,&job);
        if(rc==PATRM_RC_OK) program(&dev,&job);
        printf("%u %u",(unsigned)rc,(unsigned)mock_count);
        for(i=0;i<mock_count;i++) printf(" %u %u",(unsigned)(mock_addr[i]-PATRM_REG_BASE),(unsigned)mock_value[i]);
        puts("");
    }
    return 0;
}
"""

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT/'bsp_mock.h').write_text(BSP)
    for h in ('xil_cache','xil_exception','xil_io','xiltimer','xparameters','xpseudo_asm','xscugic','xstatus'):
        (OUT/(h+'.h')).write_text('#include "bsp_mock.h"\n')
    (OUT/'host.c').write_text(HARNESS)
    gcc=shutil.which('gcc')
    if not gcc: raise RuntimeError('host gcc is required')
    cases=[]
    def case(mode,W,H,b,modes=3,block=64,src=J.SRC_DEFAULT,dst=J.DST_DEFAULT,rc=None):
        if rc is None:
            try: J.register_image(W,H,mode,b,block,src,dst,block_len_max=64); rc=0
            except J.JobError: rc=J.RC['BAD_TRANSFORM']
        vals=[J.MODES[mode] if isinstance(mode,str) else mode,W,H,block,src,dst,*b,modes,64]
        cases.append((vals,rc))
    identity=(65536,0,0,0,65536,0)
    for mode in ('gray','bayer_a'):
        for W,H in ((16,2),(64,64),(128,96),(480,272)):
            for tf in load():
                from model.memmodel import _b_for
                case(mode,W,H,tuple(_b_for(tf,W,H)))
        case(mode,64,64,(52429,-39322,131072,39322,52429,65536))
        for tx in (-5,-3,-1,0,1,3,5):
            case(mode,64,64,(65537,-3,tx,-5,65535,-tx))
    rng=random.Random(5302)
    for _ in range(350):
        mode=rng.choice(('gray','bayer_a')); W,H=rng.choice(((16,2),(64,64),(128,96)))
        b=tuple(rng.randint(-262144,262144) for _ in range(6))
        case(mode,W,H,b)
    for _ in range(100):
        b=tuple(rng.choice((-2147483648,2147483647,0,-1,1)) for _ in range(6))
        case('bayer_a',16,2,b)
    case('bayer_a',64,64,identity,modes=1,rc=J.RC['BAD_MODE'])
    case(2,64,64,identity,modes=7,rc=J.RC['BAD_MODE'])
    case(3,64,64,identity,modes=7,rc=J.RC['BAD_MODE'])
    for mode in ('gray','bayer_a'):
        for W,H in ((0,64),(64,0),(4097,2),(60,64)):
            case(mode,W,H,identity,rc=J.RC['BAD_SIZE'])
        case(mode,64,64,identity,block=0,rc=J.RC['BAD_BLOCK_LEN'])
        case(mode,64,64,identity,src=J.SRC_DEFAULT+1,rc=J.RC['BAD_ADDR'])
        case(mode,64,64,identity,dst=J.SRC_DEFAULT,rc=J.RC['BAD_ADDR'])
    case('gray',8,1,identity)
    case('bayer_a',8,2,identity,rc=J.RC['BAD_SIZE'])
    case('bayer_a',64,63,identity,rc=J.RC['BAD_SIZE'])
    payload=''.join(' '.join(map(str,v))+'\n' for v,_ in cases)
    for opt in ('-O2','-O3'):
        exe=OUT/('driver'+opt+'.exe')
        cmd=[gcc,'-std=c99','-Wall','-Wextra','-Werror',opt,'-I'+str(OUT),'-I'+str(ROOT/'sw/patrm_drv'),
             '-I'+str(ROOT/'sw/include'),str(OUT/'host.c'),'-o',str(exe)]
        build=subprocess.run(cmd,capture_output=True,text=True)
        if build.returncode: raise RuntimeError(build.stdout+build.stderr)
        r=subprocess.run([str(exe)],input=payload,capture_output=True,text=True,check=True)
        lines=r.stdout.splitlines()
        assert len(lines)==len(cases), (len(lines),len(cases))
        for k,((v,rc),line) in enumerate(zip(cases,lines)):
            got=list(map(int,line.split())); assert got[0]==rc, (k,v,got,rc)
            if rc: assert got[1]==0; continue
            mode,W,H,block,src,dst=v[:6]; b=v[6:12]
            expected,_=J.register_image(W,H,mode,b,block,src,dst,block_len_max=64)
            writes=list(zip(got[2::2],got[3::2]))
            assert writes==[(off,val) for off,_,val in expected[:-1]], (k,v,writes,expected)
        print(f'{opt}: {len(cases)} cases, validation + all configuration writes match model/job.py; 0 compiler warnings')
    print('TEST PASS')
    return 0

if __name__=='__main__':
    try: sys.exit(main())
    except (AssertionError,RuntimeError,OSError,subprocess.SubprocessError) as e:
        print('TEST FAIL:',repr(e)); sys.exit(1)
