# Probe map of the debug ILA (build.tcl ila=1). Single source for vivado/ila_insert.tcl (which connects the probes) and
# scripts/board/ila_probes.tcl (which splits them back into named signals in the hardware manager).
#
# Five probes because the BASIC licence tier allows at most 5 ILA probes; each probe is a concatenated bus.
# Every entry: probe, description, fields from bit 0 upwards. Every field: name, engine port (patrm_top), width.

set ::ila_depth 4096
set ::ila_probes {
    {probe0 "HP0 read address" {
        {hp0_araddr  m_axi_hp0_araddr  32}
        {hp0_arlen   m_axi_hp0_arlen    4}
        {hp0_arready m_axi_hp0_arready  1}
        {hp0_arvalid m_axi_hp0_arvalid  1}}}
    {probe1 "HP0 read data" {
        {hp0_rdata   m_axi_hp0_rdata   64}
        {hp0_rresp   m_axi_hp0_rresp    2}
        {hp0_rlast   m_axi_hp0_rlast    1}
        {hp0_rready  m_axi_hp0_rready   1}
        {hp0_rvalid  m_axi_hp0_rvalid   1}}}
    {probe2 "HP1 write address" {
        {hp1_awaddr  m_axi_hp1_awaddr  32}
        {hp1_awlen   m_axi_hp1_awlen    4}
        {hp1_awready m_axi_hp1_awready  1}
        {hp1_awvalid m_axi_hp1_awvalid  1}}}
    {probe3 "HP1 write data and response" {
        {hp1_bresp   m_axi_hp1_bresp    2}
        {hp1_bready  m_axi_hp1_bready   1}
        {hp1_bvalid  m_axi_hp1_bvalid   1}
        {hp1_wdata   m_axi_hp1_wdata   64}
        {hp1_wstrb   m_axi_hp1_wstrb    8}
        {hp1_wlast   m_axi_hp1_wlast    1}
        {hp1_wready  m_axi_hp1_wready   1}
        {hp1_wvalid  m_axi_hp1_wvalid   1}}}
    {probe4 "interrupt and GP0 AXI-Lite handshakes" {
        {gp0_rvalid  s_axi_rvalid       1}
        {gp0_arvalid s_axi_arvalid      1}
        {gp0_bvalid  s_axi_bvalid       1}
        {gp0_wready  s_axi_wready       1}
        {gp0_wvalid  s_axi_wvalid       1}
        {gp0_awready s_axi_awready      1}
        {gp0_awvalid s_axi_awvalid      1}
        {interrupt   interrupt          1}}}
}

proc ila_probe_width {fields} {
    set w 0
    foreach f $fields { incr w [lindex $f 2] }
    return $w
}
