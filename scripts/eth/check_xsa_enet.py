"""Step 10.0: show that Ethernet (GEM0 = ENET0) is enabled in an XSA, without Vivado.

An XSA is a zip file; its .hwh (hardware handoff, XML) lists every PS7 parameter. This reads the ENET0 ones and checks
the values Phase 10 needs: ENET0 enabled, on MIO (the on-board RJ45 PHY), MDIO enabled, 1000 Mbps.

    python scripts/eth/check_xsa_enet.py                  (default: results/hw/rev D/patrm_gray.xsa)
    python scripts/eth/check_xsa_enet.py <file.xsa>

Last line: ENET CHECK PASS or ENET CHECK FAIL: <reason>.
"""
import re
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_XSA = REPO / "results" / "hw" / "rev D" / "patrm_gray.xsa"
NEEDED = {"PCW_ENET0_PERIPHERAL_ENABLE": "1", "PCW_ENET0_ENET0_IO": "MIO 16 .. 27",
          "PCW_ENET0_GRP_MDIO_ENABLE": "1", "PCW_ENET0_PERIPHERAL_FREQMHZ": "1000 Mbps"}


def ps7_params(xsa):
    with zipfile.ZipFile(xsa) as z:
        hwh = [n for n in z.namelist() if n.endswith(".hwh")]
        if not hwh:
            raise ValueError(f"no .hwh inside {xsa}")
        text = z.read(hwh[0]).decode("utf-8", errors="replace")
    return dict(re.findall(r'<PARAMETER NAME="(PCW_ENET0_[A-Z0-9_]+)" VALUE="([^"]*)"', text))


def main():
    xsa = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_XSA
    if not xsa.is_file():
        print(f"ENET CHECK FAIL: {xsa} not found")
        return 1
    params = ps7_params(xsa)
    print(f"XSA: {xsa}")
    for key in NEEDED:
        print(f"  {key:32s} = {params.get(key, '<missing>')}")
    wrong = [k for k, v in NEEDED.items() if params.get(k) != v]
    if wrong:
        print(f"ENET CHECK FAIL: {', '.join(f'{k} is {params.get(k)!r}, need {NEEDED[k]!r}' for k in wrong)}")
        return 1
    print("ENET CHECK PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
