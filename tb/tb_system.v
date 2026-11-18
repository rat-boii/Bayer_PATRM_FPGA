// Full-system testbench (step 4.1b): the block design of vivado/build.tcl with processing_system7_vip as the PS model.
// It acts like the ARM (spec/memory_map.md section 4) and uses only VIP API tasks for that: pre_load_mem_from_file,
// write_mem and read_mem on the VIP DDR, write_data and read_data on M_AXI_GP0, wait_interrupt and read_interrupt on
// IRQ_F2P. The monitor below only watches the engine's ports. No SystemVerilog here (D17); the VIP is AMD's own IP.
//
// Run from the repo root:
//   python scripts/gen_system_vectors.py
//   python scripts/sim_system.py
// +VEC_DIR=<folder> is the vector folder (case format: scripts/gen_system_vectors.py).
//
// Checks in every frame:
//   driver    BUILD_ID and STATUS over GP0, BUSY after START, DONE after the interrupt, DONE cleared by W1C
//   interrupt IRQ_F2P[0] rises, stays high until the W1C, then drops
//   output    the output in the VIP DDR == model frame byte for byte, guard bytes after it unchanged
//   counters  CYCLES == START to DONE - 2 (as in tb_patrm_top), BYTES_RD == memmodel == 8 x R handshakes,
//             BYTES_WR == W x H == 8 x W handshakes, AR and AW bursts == memmodel, RD_STALL + WR_STALL <= CYCLES
//   bus       bursts inside the images, at most 16 beats, not across a 4 KB boundary, WSTRB all ones
//             (bus also: W data on HP1 == model frame, AW in raster order, every B response OKAY)
// VIP write lag: the DDR model of the VIP commits an HP write burst only when the next HP write request arrives, so the
// last burst of a frame would stay pending and land later, in the next frame. After each frame the testbench therefore
// runs one 8 x 1 job into a scratch buffer (flush_vip_writes). The frame is compared only after that, in the VIP DDR.
// Rejected start: ERROR with ERR_CODE, no interrupt, no AXI traffic on HP0 or HP1, output area unchanged, counters kept.
// Prints one CASE line per case and exactly one final line: "TEST PASS" or "TEST FAIL: <reason>".
`timescale 1ns/1ps
`define PS  dut.system_i.processing_system7_0.inst
`define ENG dut.system_i.patrm_0

module tb_system;

`include "patrm_regs.vh"

    localparam [31:0] REG_BASE = 32'h43C0_0000;
    localparam [31:0] SRC      = 32'h1000_0000;
    localparam [31:0] DST      = 32'h1800_0000;
    localparam [31:0] FLUSH_DST = 32'h1C00_0000;         // scratch output of the flush job (regs_flush.txt)
    localparam FLUSH_BYTES = 8;
    localparam FLUSH_SETTLE = 200;                       // cycles for the flush request to reach the DDR model
    localparam [31:0] MARK     = 32'hA5C3_5A3C;
    localparam [31:0] BUILD_ID_EXP = 32'h0040_1001;
    localparam MAX_BYTES  = 128 * 96;
    localparam MAX_WORDS  = MAX_BYTES / 4;
    localparam MAX_REGS   = 32;
    localparam GUARD      = 64;                          // bytes checked after the output image
    localparam CHUNK      = 128;                         // largest read_mem / write_mem transfer of the VIP
    localparam PATH_BITS  = 8 * 128;                     // file name width of the VIP tasks
    localparam MSG_BITS   = 8 * 200;
    localparam QUIET_CYC  = 2000;                        // cycles watched after a rejected start
    localparam BOOT_LIMIT = 100000;

    localparam [31:0] S_BUSY  = 32'd1 << PATRM_STATUS_BUSY_LSB;
    localparam [31:0] S_DONE  = 32'd1 << PATRM_STATUS_DONE_LSB;
    localparam [31:0] S_ERROR = 32'd1 << PATRM_STATUS_ERROR_LSB;

    // ---------------- PS pins, design ----------------
    reg  ps_clk = 1'b0, ps_rstn = 1'b0;
    wire w_ps_clk = ps_clk, w_ps_rstn = ps_rstn;
    always #15 ps_clk = ~ps_clk;

    system_wrapper dut (.FIXED_IO_ps_clk(w_ps_clk), .FIXED_IO_ps_porb(w_ps_rstn), .FIXED_IO_ps_srstb(w_ps_rstn));

    // ---------------- engine ports (read only) ----------------
    wire        clk       = `ENG.aclk;
    wire        eng_rstn  = `ENG.aresetn;
    wire        interrupt = `ENG.interrupt;
    wire [6:0]  l_awaddr  = `ENG.s_axi_awaddr;
    wire [31:0] l_wdata   = `ENG.s_axi_wdata;
    wire [3:0]  l_wstrb   = `ENG.s_axi_wstrb;
    wire        l_aw      = `ENG.s_axi_awvalid & `ENG.s_axi_awready;
    wire        l_w       = `ENG.s_axi_wvalid & `ENG.s_axi_wready;
    wire        ar_hs     = `ENG.m_axi_hp0_arvalid & `ENG.m_axi_hp0_arready;
    wire        r_hs      = `ENG.m_axi_hp0_rvalid & `ENG.m_axi_hp0_rready;
    wire        aw_hs     = `ENG.m_axi_hp1_awvalid & `ENG.m_axi_hp1_awready;
    wire        w_hs      = `ENG.m_axi_hp1_wvalid & `ENG.m_axi_hp1_wready;
    wire [31:0] araddr    = `ENG.m_axi_hp0_araddr;
    wire [31:0] awaddr    = `ENG.m_axi_hp1_awaddr;
    wire [3:0]  arlen     = `ENG.m_axi_hp0_arlen;
    wire [3:0]  awlen     = `ENG.m_axi_hp1_awlen;
    wire [7:0]  wstrb     = `ENG.m_axi_hp1_wstrb;
    wire [63:0] wdata     = `ENG.m_axi_hp1_wdata;
    wire        b_hs      = `ENG.m_axi_hp1_bvalid & `ENG.m_axi_hp1_bready;
    wire [1:0]  bresp     = `ENG.m_axi_hp1_bresp;

    // ---------------- case data ----------------
    reg [31:0] srcw [0:MAX_WORDS-1];
    reg [31:0] expw [0:MAX_WORDS-1];
    reg [31:0] r_off [0:MAX_REGS-1];
    reg [31:0] r_val [0:MAX_REGS-1];
    reg [PATH_BITS-1:0] vecdir, path, c_name, c_regs, c_src, c_exp;
    reg [MSG_BITS-1:0]  msg, first_fail;
    integer c_kind, c_W, c_H, c_bytes, c_rb, c_wb, c_err, npix, n_regs;
    integer fd_cases, fd, r, i;
    integer nfail = 0, n_frames = 0, n_rejected = 0, n_irq = 0, total_bytes = 0;
    reg     finished = 1'b0;

    // ---------------- results and failures ----------------
    task finish_fail;
        input [MSG_BITS-1:0] m;
        begin
            if (!finished) begin
                finished = 1'b1;
                $display("TEST FAIL: %0s", m);
                $finish;
            end
        end
    endtask

    task record_fail;
        input [MSG_BITS-1:0] m;
        begin
            if (nfail == 0) first_fail = m;
            nfail = nfail + 1;
            $display("  CHECK FAILED (%0s): %0s", c_name, m);
        end
    endtask

    task chk_eq;
        input [31:0] got;
        input [31:0] want;
        input [MSG_BITS-1:0] what;
        begin
            if (got !== want) begin
                $sformat(msg, "%0s = 0x%08h (%0d), expected 0x%08h (%0d)", what, got, got, want, want);
                record_fail(msg);
            end
        end
    endtask

    task chk;
        input ok;
        input [MSG_BITS-1:0] what;
        begin
            if (ok !== 1'b1) record_fail(what);
        end
    endtask

    // ---------------- monitor: sampled at the falling edge, when every handshake signal is stable ----------------
    integer cyc = 0, wd_start = 0, wd_limit = BOOT_LIMIT;
    integer n_ar = 0, n_r = 0, n_aw = 0, n_w = 0, n_b = 0, n_irq_cyc = 0, bus_err = 0;
    integer t_start = 0, t_irq = 0;
    integer aw_next = 0, w_off = 0, wdata_bad = 0, wdata_first = -1;   // byte offsets of the frame on HP1
    reg     check_wdata = 1'b0;
    reg [31:0] aw_base = DST;                            // where the running job may read and write
    integer mon_n = 0;
    realtime rt_start = 0, rt_irq = 0;
    reg arm_start = 1'b0, start_seen = 1'b0, irq_seen = 1'b0;

    always @(negedge clk) begin
        cyc = cyc + 1;
        if (cyc - wd_start > wd_limit) begin
            $sformat(msg, "%0s: no progress for %0d clock cycles (BUSY or a GP0 access hangs)", c_name, wd_limit);
            finish_fail(msg);
        end
        if (eng_rstn === 1'b1) begin
            if (ar_hs === 1'b1) begin
                n_ar = n_ar + 1;
                if (araddr < SRC || araddr + 8 * (arlen + 1) > SRC + mon_n ||
                    araddr[11:0] + 8 * (arlen + 1) > 4096) bus_err = bus_err + 1;
            end
            if (aw_hs === 1'b1) begin
                n_aw = n_aw + 1;
                if (awaddr < aw_base || awaddr + 8 * (awlen + 1) > aw_base + mon_n ||
                    awaddr[11:0] + 8 * (awlen + 1) > 4096) bus_err = bus_err + 1;
                if (awaddr !== aw_base + aw_next) bus_err = bus_err + 1;       // the output is written in raster order
                aw_next = aw_next + 8 * (awlen + 1);
            end
            if (r_hs === 1'b1) n_r = n_r + 1;
            if (b_hs === 1'b1) begin
                n_b = n_b + 1;
                if (bresp !== 2'b00) bus_err = bus_err + 1;
            end
            if (w_hs === 1'b1) begin
                n_w = n_w + 1;
                if (wstrb !== 8'hFF) bus_err = bus_err + 1;
                if (check_wdata && w_off < npix &&
                    wdata !== {expw[w_off / 4 + 1], expw[w_off / 4]}) begin
                    if (wdata_bad == 0) wdata_first = w_off;
                    wdata_bad = wdata_bad + 1;
                end
                w_off = w_off + 8;
            end
            if (interrupt === 1'b1) n_irq_cyc = n_irq_cyc + 1;
            if (arm_start && l_aw === 1'b1 && l_w === 1'b1 && l_awaddr[6:2] == (PATRM_REG_CTRL >> 2) &&
                l_wstrb[0] && l_wdata[PATRM_CTRL_START_LSB]) begin
                arm_start = 1'b0; start_seen = 1'b1; irq_seen = 1'b0;
                t_start = cyc; rt_start = $realtime;
            end else if (start_seen && !irq_seen && interrupt === 1'b1) begin
                irq_seen = 1'b1; t_irq = cyc; rt_irq = $realtime;
            end
        end
    end

    // ---------------- the ARM side: VIP API only ----------------
    reg [2047:0] gp_rd;
    reg [1:0]    gp_resp;

    task reg_write;
        input [31:0] off;
        input [31:0] val;
        begin
            `PS.write_data(REG_BASE + off, 4, val, gp_resp);
            if (gp_resp !== 2'b00) begin
                $sformat(msg, "GP0 write to offset 0x%02h: response %b", off, gp_resp);
                record_fail(msg);
            end
        end
    endtask

    task reg_read;
        input  [31:0] off;
        output [31:0] val;
        begin
            `PS.read_data(REG_BASE + off, 4, gp_rd, gp_resp);
            val = gp_rd[31:0];
            if (gp_resp !== 2'b00) begin
                $sformat(msg, "GP0 read of offset 0x%02h: response %b", off, gp_resp);
                record_fail(msg);
            end
        end
    endtask

    task fill_marker;                                    // output area and guard bytes
        input integer nbytes;
        integer off, n;
        reg [1023:0] d;
        begin
            d = {32{MARK}};
            off = 0;
            while (off < nbytes) begin
                n = (nbytes - off < CHUNK) ? nbytes - off : CHUNK;
                `PS.write_mem(d, DST + off, n);
                off = off + n;
            end
        end
    endtask

    // Compares nbytes of the VIP DDR at base, byte for byte, with: 0 = srcw, 1 = expw, 2 = the marker.
    integer cmp_bad, cmp_first;
    task mem_compare;
        input [31:0]  base;
        input integer nbytes;
        input integer what;
        input integer offset0;                           // byte offset of base inside the marker pattern
        integer off, n, k, idx;
        reg [1023:0] d;
        reg [7:0] got, want;
        reg [31:0] word;
        begin
            cmp_bad = 0; cmp_first = -1;
            off = 0;
            while (off < nbytes) begin
                n = (nbytes - off < CHUNK) ? nbytes - off : CHUNK;
                `PS.read_mem(base + off, n, d);
                for (k = 0; k < n; k = k + 1) begin
                    idx = off + k;
                    got = d[8 * k +: 8];
                    case (what)
                        0:       word = srcw[idx / 4];
                        1:       word = expw[idx / 4];
                        default: word = MARK;
                    endcase
                    want = word[8 * ((idx + offset0) % 4) +: 8];
                    if (got !== want) begin
                        if (cmp_bad == 0) cmp_first = idx;
                        cmp_bad = cmp_bad + 1;
                    end
                end
                off = off + n;
            end
        end
    endtask

    task load_regs;
        begin
            $sformat(path, "%0s/%0s", vecdir, c_regs);
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $sformat(msg, "cannot open %0s (run python scripts/gen_system_vectors.py)", path);
                finish_fail(msg);
            end
            n_regs = 0;
            while ($fscanf(fd, "%h %h", r_off[n_regs], r_val[n_regs]) == 2) n_regs = n_regs + 1;
            $fclose(fd);
            if (n_regs == 0 || r_off[n_regs-1] !== {25'd0, PATRM_REG_CTRL}) finish_fail("register list must end with CTRL");
        end
    endtask

    task load_source;
        begin
            $sformat(path, "%0s/%0s", vecdir, c_src);
            $readmemh(path, srcw, 0, npix / 4 - 1);
            if (^srcw[npix / 4 - 1] === 1'bx) begin
                $sformat(msg, "cannot read %0s (run python scripts/gen_system_vectors.py)", path);
                finish_fail(msg);
            end
            // $readmemh inside the VIP takes the last argument as a count of 32-bit memory words
            `PS.pre_load_mem_from_file(path, SRC, npix / 4);
            mem_compare(SRC, npix, 0, 0);
            chk_eq(cmp_bad, 0, "source bytes differing after the load into the VIP DDR");
        end
    endtask

    task write_job;                                      // driver steps 5 to 7, CTRL with START last
        begin
            for (i = 0; i < n_regs - 1; i = i + 1) reg_write(r_off[i], r_val[i]);
            arm_start = 1'b1;
            reg_write(r_off[n_regs-1], r_val[n_regs-1]);
        end
    endtask

    task idle;
        input integer n;
        begin
            repeat (n) @(negedge clk);
        end
    endtask

    // Pushes the last write burst of the frame out of the VIP (see the header). Polls: this job has IRQ_EN = 0.
    task flush_vip_writes;
        reg [31:0] rv;
        integer    aw0, irq0;
        begin
            c_regs = "regs_flush.txt";
            load_regs;
            aw0 = n_aw; irq0 = n_irq_cyc;
            aw_base = FLUSH_DST; mon_n = FLUSH_BYTES; aw_next = 0;
            for (i = 0; i < n_regs; i = i + 1) reg_write(r_off[i], r_val[i]);
            reg_read(PATRM_REG_STATUS, rv);
            while (rv & S_BUSY) reg_read(PATRM_REG_STATUS, rv);
            chk_eq(rv, S_DONE, "STATUS after the flush job");
            reg_write(PATRM_REG_STATUS, S_DONE);
            idle(FLUSH_SETTLE);
            aw_base = DST; mon_n = npix;
            reg_read(PATRM_REG_STATUS, rv);
            chk_eq(rv, 0, "STATUS after the W1C of the flush job");
            chk_eq(n_aw - aw0, 1, "AW bursts of the flush job");
            chk_eq(n_irq_cyc - irq0, 0, "interrupt cycles during the flush job");
        end
    endtask

    // ---------------- one frame ----------------
    task run_frame;
        reg [31:0]  rv, cycles, bytes_rd, bytes_wr, rd_stall, wr_stall;
        reg [15:0]  irq;
        integer     ar0, r0, aw0, w0, b0, match, ar_cnt, aw_cnt;
        realtime    rt0;
        begin
            rt0 = $realtime;
            mon_n = npix;
            load_source;
            $sformat(path, "%0s/%0s", vecdir, c_exp);
            $readmemh(path, expw, 0, npix / 4 - 1);
            if (^expw[npix / 4 - 1] === 1'bx) finish_fail("cannot read the expected frame");
            fill_marker(npix + GUARD);

            reg_read(PATRM_REG_STATUS, rv);
            chk_eq(rv & S_BUSY, 0, "STATUS.BUSY before the job");
            reg_write(PATRM_REG_STATUS, S_DONE | S_ERROR);
            ar0 = n_ar; r0 = n_r; aw0 = n_aw; w0 = n_w; b0 = n_b; start_seen = 1'b0; irq_seen = 1'b0;
            aw_next = 0; w_off = 0; wdata_bad = 0; wdata_first = -1; check_wdata = 1'b1;
            write_job;
            reg_read(PATRM_REG_STATUS, rv);
            chk_eq(rv, S_BUSY, "first STATUS read after START");

            `PS.wait_interrupt(4'd0, irq);
            chk(irq[0], "IRQ_F2P[0] after wait_interrupt");
            n_irq = n_irq + 1;
            idle(2);
            chk(start_seen, "the monitor saw the START write");
            chk(irq_seen, "the monitor saw the interrupt");

            reg_read(PATRM_REG_STATUS, rv);
            chk_eq(rv, S_DONE, "STATUS after the interrupt");
            `PS.read_interrupt(irq);
            chk(irq[0], "IRQ_F2P[0] stays high until DONE is cleared");

            reg_read(PATRM_REG_CYCLES, cycles);
            chk_eq(cycles, t_irq - t_start - 2, "CYCLES vs START to DONE");
            reg_read(PATRM_REG_BYTES_RD, bytes_rd);
            chk_eq(bytes_rd, c_bytes, "BYTES_RD vs memmodel");
            chk_eq(bytes_rd, 8 * (n_r - r0), "BYTES_RD vs R handshakes on HP0");
            reg_read(PATRM_REG_BYTES_WR, bytes_wr);
            chk_eq(bytes_wr, npix, "BYTES_WR vs W x H");
            chk_eq(bytes_wr, 8 * (n_w - w0), "BYTES_WR vs W handshakes on HP1");
            reg_read(PATRM_REG_RD_STALL, rd_stall);
            reg_read(PATRM_REG_WR_STALL, wr_stall);
            chk(rd_stall + wr_stall <= cycles, "RD_STALL + WR_STALL <= CYCLES");
            ar_cnt = n_ar - ar0; aw_cnt = n_aw - aw0;    // before the flush job adds its own bursts
            chk_eq(ar_cnt, c_rb, "AR bursts on HP0 vs memmodel");
            chk_eq(aw_cnt, c_wb, "AW bursts on HP1 vs memmodel");

            reg_write(PATRM_REG_STATUS, S_DONE);         // W1C
            idle(4);
            `PS.read_interrupt(irq);
            chk(irq[0] === 1'b0, "IRQ_F2P[0] drops after the W1C of DONE");
            chk(interrupt === 1'b0, "engine interrupt output drops after the W1C of DONE");
            reg_read(PATRM_REG_STATUS, rv);
            chk_eq(rv, 0, "STATUS after the W1C of DONE");

            check_wdata = 1'b0;
            chk_eq(wdata_bad, 0, "W beats on HP1 differing from the model");
            chk_eq(n_b - b0, c_wb, "B responses on HP1 vs memmodel");
            flush_vip_writes;

            mem_compare(DST, npix, 1, 0);
            match = (cmp_bad == 0);
            if (!match) begin
                $sformat(msg, "%0d of %0d output bytes differ from the model, first at byte %0d", cmp_bad, npix, cmp_first);
                record_fail(msg);
            end
            mem_compare(DST + npix, GUARD, 2, npix);
            chk_eq(cmp_bad, 0, "guard bytes changed after the output image");
            chk_eq(bus_err, 0, "AXI burst rule violations on HP0 / HP1");

            n_frames = n_frames + 1;
            total_bytes = total_bytes + npix;
            $display("CASE %0s %0dx%0d match=%0d CYCLES=%0d BYTES_RD=%0d memmodel=%0d BYTES_WR=%0d WxH=%0d RD_STALL=%0d WR_STALL=%0d AR=%0d AW=%0d hp1_beats_differ=%0d irq=seen,cleared frame_us=%0.2f case_us=%0.2f",
                     c_name, c_W, c_H, match, cycles, bytes_rd, c_bytes, bytes_wr, npix, rd_stall, wr_stall,
                     ar_cnt, aw_cnt, wdata_bad, (rt_irq - rt_start) / 1000.0, ($realtime - rt0) / 1000.0);
        end
    endtask

    // ---------------- one rejected start ----------------
    task run_rejected;
        reg [31:0]  rv, c0, br0, bw0, v;
        reg [15:0]  irq;
        integer     ar0, r0, aw0, w0, irq0, written;
        realtime    rt0;
        begin
            rt0 = $realtime;
            mon_n = npix;
            fill_marker(npix + GUARD);
            reg_read(PATRM_REG_CYCLES, c0);
            reg_read(PATRM_REG_BYTES_RD, br0);
            reg_read(PATRM_REG_BYTES_WR, bw0);
            reg_write(PATRM_REG_STATUS, S_DONE | S_ERROR);
            ar0 = n_ar; r0 = n_r; aw0 = n_aw; w0 = n_w; irq0 = n_irq_cyc; start_seen = 1'b0;
            write_job;
            reg_read(PATRM_REG_STATUS, rv);
            chk_eq(rv, S_ERROR | (c_err << PATRM_STATUS_ERR_CODE_LSB), "STATUS after the rejected start");
            idle(QUIET_CYC);
            reg_read(PATRM_REG_STATUS, rv);
            chk_eq(rv, S_ERROR | (c_err << PATRM_STATUS_ERR_CODE_LSB), "STATUS after waiting");
            chk(start_seen, "the monitor saw the START write");
            `PS.read_interrupt(irq);
            chk(irq[0] === 1'b0, "no IRQ_F2P[0] after a rejected start");
            chk_eq(n_irq_cyc - irq0, 0, "cycles with the interrupt high after a rejected start");
            chk_eq(n_ar - ar0, 0, "AR bursts after a rejected start");
            chk_eq(n_r - r0, 0, "R beats after a rejected start");
            chk_eq(n_aw - aw0, 0, "AW bursts after a rejected start");
            chk_eq(n_w - w0, 0, "W beats after a rejected start");
            reg_read(PATRM_REG_CYCLES, v);   chk_eq(v, c0, "CYCLES kept after a rejected start");
            reg_read(PATRM_REG_BYTES_RD, v); chk_eq(v, br0, "BYTES_RD kept after a rejected start");
            reg_read(PATRM_REG_BYTES_WR, v); chk_eq(v, bw0, "BYTES_WR kept after a rejected start");
            mem_compare(DST, npix + GUARD, 2, 0);
            written = cmp_bad;
            chk_eq(written, 0, "output bytes changed by a rejected start");
            reg_write(PATRM_REG_STATUS, S_ERROR);        // W1C
            reg_read(PATRM_REG_STATUS, rv);
            chk_eq(rv & (S_BUSY | S_DONE | S_ERROR), 0, "STATUS after the W1C of ERROR");
            n_rejected = n_rejected + 1;
            $display("CASE %0s %0dx%0d rejected=1 ERR_CODE=%0d bytes_changed=%0d AR=%0d AW=%0d interrupt_cycles=%0d case_us=%0.2f",
                     c_name, c_W, c_H, c_err, written, n_ar - ar0, n_aw - aw0, n_irq_cyc - irq0, ($realtime - rt0) / 1000.0);
        end
    endtask

    // ---------------- main ----------------
    reg [31:0] v0;
    initial begin
        c_name = "startup";
        npix = 0;
        if (!$value$plusargs("VEC_DIR=%s", vecdir)) vecdir = "../../../../../../../data/vectors/system";
        `PS.set_debug_level_info(1'b0);
        `PS.set_stop_on_error(1'b0);
        #300 ps_rstn = 1'b1;
        #300 `PS.fpga_soft_reset(32'h1);                 // FCLK_RESET0_N low
        #300 `PS.fpga_soft_reset(32'h0);
        wait (eng_rstn === 1'b1);
        idle(20);

        reg_read(PATRM_REG_BUILD_ID, v0);
        chk_eq(v0, BUILD_ID_EXP, "BUILD_ID");
        $display("BUILD_ID 0x%08h over GP0 (expected 0x%08h)", v0, BUILD_ID_EXP);
        reg_read(PATRM_REG_STATUS, v0);
        chk_eq(v0, 0, "STATUS after reset");
        $display("STATUS 0x%08h over GP0", v0);

        $sformat(path, "%0s/cases.txt", vecdir);
        fd_cases = $fopen(path, "r");
        if (fd_cases == 0) begin
            $sformat(msg, "cannot open %0s (run python scripts/gen_system_vectors.py)", path);
            finish_fail(msg);
        end
        r = $fscanf(fd_cases, "%d %s %d %d %d %d %d %d %s %s %s", c_kind, c_name, c_W, c_H, c_bytes, c_rb, c_wb, c_err,
                    c_regs, c_src, c_exp);
        while (r == 11) begin
            npix = c_W * c_H;
            if (npix > MAX_BYTES) finish_fail("frame larger than the testbench arrays");
            wd_start = cyc;
            wd_limit = 400 * npix + 500000;
            load_regs;
            if (c_kind == 0) run_frame; else run_rejected;
            r = $fscanf(fd_cases, "%d %s %d %d %d %d %d %d %s %s %s", c_kind, c_name, c_W, c_H, c_bytes, c_rb, c_wb, c_err,
                        c_regs, c_src, c_exp);
        end
        $fclose(fd_cases);
        wd_limit = 2000000000;

        $display("totals: %0d frames, %0d output bytes compared, %0d interrupts seen and cleared, %0d rejected starts, %0d check errors",
                 n_frames, total_bytes, n_irq, n_rejected, nfail);
        if (n_frames == 0 || n_rejected == 0) finish_fail("the case list has no frame or no rejected start");
        if (nfail != 0) begin
            $sformat(msg, "%0d check errors, first: %0s", nfail, first_fail);
            finish_fail(msg);
        end
        if (!finished) begin
            finished = 1'b1;
            $display("TEST PASS");
            $finish;
        end
    end
endmodule

`undef PS
`undef ENG
