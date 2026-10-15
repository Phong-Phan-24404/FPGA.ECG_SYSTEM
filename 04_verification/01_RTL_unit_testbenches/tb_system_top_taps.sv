// Per-layer intermediate tap comparison for ecg_accel_top (Phase 1, CP-3).
//
// tb_system_top_regression proves the five logits are right. It cannot say
// *where* the network went wrong when they are not. This testbench watches
// every inter-layer AXI-Stream inside the top level and compares each beat
// against the corresponding golden tap file, so a failure is localised to one
// layer instead of to "the network".
//
// Runs sample_0 only, with REGISTERED_MATH=1. Coverage across all five samples
// is tb_system_top_regression's job.

`timescale 1ns / 1ps

import ecg_params_pkg::*;

module tb_system_top_taps;

    localparam int DATA_WIDTH = 16;
    // 19 taps since CP2-4: relu6 no longer exists as a separate stage, it is fused
    // into i_gpool. Its coverage moved to tb_relu_global_maxpool1d, which checks
    // the fused block against a behavioural relu-then-max model; the pooled
    // output below still validates the result end to end.
    localparam int NUM_TAPS   = 19;
    localparam int MAX_BEATS  = 10240;

    localparam SAMPLE_DIR = "datasets/golden_fixed/test_vectors_hex/sample_0/";

    logic                  aclk;
    logic                  aresetn;

    logic [DATA_WIDTH-1:0] s_axis_tdata;
    logic                  s_axis_tvalid;
    logic                  s_axis_tready;
    logic                  s_axis_tlast;

    logic [DATA_WIDTH-1:0] m_axis_tdata;
    logic                  m_axis_tvalid;
    logic                  m_axis_tready;
    logic                  m_axis_tlast;

    logic                  ctrl_start;
    logic                  ctrl_done;
    logic                  ctrl_idle;

    logic [DATA_WIDTH-1:0] input_mem [0:CONV1_IN_STEPS-1];

    ecg_accel_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .REGISTERED_MATH(1)
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),
        .ctrl_start(ctrl_start),
        .ctrl_done(ctrl_done),
        .ctrl_idle(ctrl_idle)
    );

    always #5 aclk = ~aclk;

    int seed = 32'h0BADF00D;
    int stall_chance = 30;

    initial begin
        if ($value$plusargs("SEED=%d", seed)) begin
            $display("[TB] Overriding seed to %0d", seed);
        end
        if ($value$plusargs("STALL_CHANCE=%d", stall_chance)) begin
            $display("[TB] Overriding stall_chance to %0d%%", stall_chance);
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tready <= 1'b1;
        end else begin
            m_axis_tready <= ($dist_uniform(seed, 0, 99) >= stall_chance);
        end
    end

    // ---------------------------------------------------------------------
    // Tap bundle. Index order follows the dataflow, so the first red row in
    // the summary table is the first layer that went wrong.
    // ---------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] tap_tdata  [0:NUM_TAPS-1];
    logic                  tap_tvalid [0:NUM_TAPS-1];
    logic                  tap_tready [0:NUM_TAPS-1];

    assign tap_tdata[ 0] = dut.c1_tdata;  assign tap_tvalid[ 0] = dut.c1_tvalid;  assign tap_tready[ 0] = dut.c1_tready;
    assign tap_tdata[ 1] = dut.r1_tdata;  assign tap_tvalid[ 1] = dut.r1_tvalid;  assign tap_tready[ 1] = dut.r1_tready;
    assign tap_tdata[ 2] = dut.c2_tdata;  assign tap_tvalid[ 2] = dut.c2_tvalid;  assign tap_tready[ 2] = dut.c2_tready;
    assign tap_tdata[ 3] = dut.r2_tdata;  assign tap_tvalid[ 3] = dut.r2_tvalid;  assign tap_tready[ 3] = dut.r2_tready;
    assign tap_tdata[ 4] = dut.p1_tdata;  assign tap_tvalid[ 4] = dut.p1_tvalid;  assign tap_tready[ 4] = dut.p1_tready;
    assign tap_tdata[ 5] = dut.c3_tdata;  assign tap_tvalid[ 5] = dut.c3_tvalid;  assign tap_tready[ 5] = dut.c3_tready;
    assign tap_tdata[ 6] = dut.r3_tdata;  assign tap_tvalid[ 6] = dut.r3_tvalid;  assign tap_tready[ 6] = dut.r3_tready;
    assign tap_tdata[ 7] = dut.c4_tdata;  assign tap_tvalid[ 7] = dut.c4_tvalid;  assign tap_tready[ 7] = dut.c4_tready;
    assign tap_tdata[ 8] = dut.r4_tdata;  assign tap_tvalid[ 8] = dut.r4_tvalid;  assign tap_tready[ 8] = dut.r4_tready;
    assign tap_tdata[ 9] = dut.p2_tdata;  assign tap_tvalid[ 9] = dut.p2_tvalid;  assign tap_tready[ 9] = dut.p2_tready;
    assign tap_tdata[10] = dut.c5_tdata;  assign tap_tvalid[10] = dut.c5_tvalid;  assign tap_tready[10] = dut.c5_tready;
    assign tap_tdata[11] = dut.r5_tdata;  assign tap_tvalid[11] = dut.r5_tvalid;  assign tap_tready[11] = dut.r5_tready;
    assign tap_tdata[12] = dut.c6_tdata;  assign tap_tvalid[12] = dut.c6_tvalid;  assign tap_tready[12] = dut.c6_tready;
    assign tap_tdata[13] = dut.gp_tdata;  assign tap_tvalid[13] = dut.gp_tvalid;  assign tap_tready[13] = dut.gp_tready;
    assign tap_tdata[14] = dut.f1_tdata;  assign tap_tvalid[14] = dut.f1_tvalid;  assign tap_tready[14] = dut.f1_tready;
    assign tap_tdata[15] = dut.r7_tdata;  assign tap_tvalid[15] = dut.r7_tvalid;  assign tap_tready[15] = dut.r7_tready;
    assign tap_tdata[16] = dut.f2_tdata;  assign tap_tvalid[16] = dut.f2_tvalid;  assign tap_tready[16] = dut.f2_tready;
    assign tap_tdata[17] = dut.r8_tdata;  assign tap_tvalid[17] = dut.r8_tvalid;  assign tap_tready[17] = dut.r8_tready;
    assign tap_tdata[18] = m_axis_tdata;  assign tap_tvalid[18] = m_axis_tvalid;  assign tap_tready[18] = m_axis_tready;

    logic [DATA_WIDTH-1:0] golden   [0:NUM_TAPS-1][0:MAX_BEATS-1];
    logic [DATA_WIDTH-1:0] load_buf [0:MAX_BEATS-1];
    int    tap_len   [0:NUM_TAPS-1];
    string tap_name  [0:NUM_TAPS-1];
    string tap_file  [0:NUM_TAPS-1];
    int    tap_cnt   [0:NUM_TAPS-1];
    int    tap_err   [0:NUM_TAPS-1];

    // Per-layer timing profile: the cycle of each tap's first and last accepted
    // beat, counted from the start pulse.
    int    tap_first [0:NUM_TAPS-1];
    int    tap_last  [0:NUM_TAPS-1];

    // ---------------------------------------------------------------------
    // AXI4-Stream handshake profile (CP2-3 entry measurement).
    //
    // AXI4-Stream defines four handshake states per clock, and two of them say
    // exactly where a pipeline loses time:
    //
    //   TVALID & TREADY   transfer
    //   TVALID & !TREADY  producer is BLOCKED by its consumer
    //   !TVALID & TREADY  consumer is STARVED by its producer
    //   neither           both idle
    //
    // This is the standard's own handshake semantics, not an ad-hoc scheme, and
    // it separates "waiting for work" from "waiting to hand work on" — which the
    // first/last beat timestamps cannot do. Every stage currently *looks*
    // blocked in the span table, and they cannot all be blocked at once.
    //
    // Counters live in the testbench, so this costs nothing in RTL, synthesis,
    // timing or BRAM, and does not touch the frozen CNN_wrapper interface. For
    // on-hardware profiling later, the equivalent standard is the Arm CoreSight
    // PMU register layout — that is a Phase 3 concern, not this measurement.
    // ---------------------------------------------------------------------
    int hs_xfer    [0:NUM_TAPS-1];
    int hs_blocked [0:NUM_TAPS-1];
    int hs_starved [0:NUM_TAPS-1];

    // The external input stream is stage conv1's producer, so it needs the same
    // treatment to tell a starved conv1 from a blocked one.
    int in_xfer   = 0;
    int in_blocked = 0;
    int in_starved = 0;

    // CP2-3 inserted a decoupling FIFO between relu5 and conv6, so tap 11 (r5)
    // is now the FIFO's INPUT. conv6's real input is the FIFO output, and that
    // is the stream whose starvation the checkpoint is trying to remove — watch
    // it directly, plus the buffer's occupancy, so the fix can be shown to work
    // rather than inferred from the frame time.
    int c6in_xfer    = 0;
    int c6in_blocked = 0;
    int c6in_starved = 0;
    int c6_fifo_peak = 0;

    logic monitor_active = 1'b0;
    int   cycle_count    = 0;

    always @(posedge aclk) begin
        if (!aresetn) begin
            cycle_count <= 0;
        end else if (monitor_active) begin
            cycle_count <= cycle_count + 1;
        end
    end

    task automatic declare_tap(input int idx, input string name,
                               input string fname, input int beats);
        tap_name[idx] = name;
        tap_file[idx] = {SAMPLE_DIR, fname};
        tap_len[idx]   = beats;
        tap_cnt[idx]   = 0;
        tap_err[idx]   = 0;
        tap_first[idx] = -1;
        tap_last[idx]  = -1;
        hs_xfer[idx]    = 0;
        hs_blocked[idx] = 0;
        hs_starved[idx] = 0;
    endtask

    initial begin
        // name              golden file                beats
        declare_tap( 0, "conv1  [P16]",     "conv1.hex",            2928);
        declare_tap( 1, "relu1",           "relu1.hex",            2928);
        declare_tap( 2, "conv2  [P4]",      "conv2.hex",            2864);
        declare_tap( 3, "relu2",           "relu2.hex",            2864);
        declare_tap( 4, "pool1",           "pool1.hex",            1424);
        declare_tap( 5, "conv3  [P4]",      "conv3.hex",            2784);
        declare_tap( 6, "relu3",           "relu3.hex",            2784);
        declare_tap( 7, "conv4  [P8]",      "conv4.hex",        2720);
        declare_tap( 8, "relu4",           "relu4.hex",            2720);
        declare_tap( 9, "pool2",           "pool2.hex",            1344);
        declare_tap(10, "conv5  [P16]",     "conv5.hex",       10240);
        declare_tap(11, "relu5",           "relu5.hex",           10240);
        declare_tap(12, "conv6 [P32 K3]", "conv6.hex",        9728);
        declare_tap(13, "global_max_pool", "global_max_pool.hex",   256);
        declare_tap(14, "fc1    [P16]",     "fc1.hex",                64);
        declare_tap(15, "relu7",           "relu7.hex",              64);
        declare_tap(16, "fc2    [P8]",      "fc2.hex",                64);
        declare_tap(17, "relu8",           "relu8.hex",              64);
        declare_tap(18, "logits",          "logits.hex",              5);

        // Icarus cannot $readmemh directly into a slice of a 2-D unpacked
        // array, so each file lands in a 1-D scratch buffer first.
        for (int t = 0; t < NUM_TAPS; t = t + 1) begin
            for (int i = 0; i < MAX_BEATS; i = i + 1) begin
                load_buf[i] = 'x;
            end
            // Explicit address range: the scratch buffer is sized for the
            // largest tap, so an unbounded read would warn "not enough words"
            // on every shorter file.
            $readmemh(tap_file[t], load_buf, 0, tap_len[t] - 1);
            for (int i = 0; i < MAX_BEATS; i = i + 1) begin
                golden[t][i] = load_buf[i];
            end
        end
        $readmemh({SAMPLE_DIR, "input.hex"}, input_mem);
    end

    // ---------------------------------------------------------------------
    // One scoreboard per tap. Compares every accepted beat, bit for bit, and
    // reports only the first three mismatches per tap so a broken early layer
    // cannot bury the rest of the table.
    // ---------------------------------------------------------------------
    genvar gt;
    generate
        for (gt = 0; gt < NUM_TAPS; gt = gt + 1) begin : gen_tap_monitor
            always @(posedge aclk) begin
                if (aresetn && monitor_active && tap_tvalid[gt] && tap_tready[gt]) begin
                    if (tap_cnt[gt] < tap_len[gt]) begin
                        if (tap_tdata[gt] !== golden[gt][tap_cnt[gt]]) begin
                            tap_err[gt] = tap_err[gt] + 1;
                            if (tap_err[gt] <= 3) begin
                                $display("[ERROR] tap %s beat %0d: expected 0x%04H, got 0x%04H",
                                         tap_name[gt], tap_cnt[gt],
                                         golden[gt][tap_cnt[gt]], tap_tdata[gt]);
                            end
                        end
                    end else begin
                        tap_err[gt] = tap_err[gt] + 1;
                        if (tap_err[gt] <= 3) begin
                            $display("[ERROR] tap %s produced beat %0d beyond its golden length %0d",
                                     tap_name[gt], tap_cnt[gt], tap_len[gt]);
                        end
                    end
                    if (tap_first[gt] < 0) begin
                        tap_first[gt] = cycle_count;
                    end
                    tap_last[gt] = cycle_count;
                    tap_cnt[gt]  = tap_cnt[gt] + 1;
                end
            end

            // Handshake state census on the same stream, every cycle of the
            // frame — not only on accepted beats.
            always @(posedge aclk) begin
                if (aresetn && monitor_active) begin
                    if (tap_tvalid[gt] && tap_tready[gt]) begin
                        hs_xfer[gt] <= hs_xfer[gt] + 1;
                    end else if (tap_tvalid[gt] && !tap_tready[gt]) begin
                        hs_blocked[gt] <= hs_blocked[gt] + 1;
                    end else if (!tap_tvalid[gt] && tap_tready[gt]) begin
                        hs_starved[gt] <= hs_starved[gt] + 1;
                    end
                end
            end
        end
    endgenerate

    // Same census on the external input stream feeding conv1.
    always @(posedge aclk) begin
        if (aresetn && monitor_active) begin
            if (s_axis_tvalid && s_axis_tready) begin
                in_xfer <= in_xfer + 1;
            end else if (s_axis_tvalid && !s_axis_tready) begin
                in_blocked <= in_blocked + 1;
            end else if (!s_axis_tvalid && s_axis_tready) begin
                in_starved <= in_starved + 1;
            end
        end
    end

    // And on conv6's real input, downstream of the CP2-3 decoupling FIFO.
    always @(posedge aclk) begin
        if (aresetn && monitor_active) begin
            if (dut.c6in_tvalid && dut.c6in_tready) begin
                c6in_xfer <= c6in_xfer + 1;
            end else if (dut.c6in_tvalid && !dut.c6in_tready) begin
                c6in_blocked <= c6in_blocked + 1;
            end else if (!dut.c6in_tvalid && dut.c6in_tready) begin
                c6in_starved <= c6in_starved + 1;
            end
            if (int'(dut.i_conv6_in_fifo.level) > c6_fifo_peak) begin
                c6_fifo_peak <= int'(dut.i_conv6_in_fifo.level);
            end
        end
    end

    initial begin
        #400000000;
        $display("[FAIL] tb_system_top_taps timeout — logits beat count %0d/5", tap_cnt[NUM_TAPS-1]);
        $finish;
    end

    int total_err;
    int shape_err;
    int frame_cycles;
    int stage_starved;
    int stage_blocked;
    int stage_busy;
    initial begin
        aclk          = 0;
        aresetn       = 0;
        s_axis_tdata  = '0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        ctrl_start    = 1'b0;

        #20;
        aresetn = 1;
        #20;

        $display("==================================================");
        $display("Running tb_system_top_taps (per-layer golden taps, sample_0)");
        $display("==================================================");

        @(posedge aclk);
        ctrl_start = 1'b1;
        @(posedge aclk);
        ctrl_start = 1'b0;

        monitor_active = 1'b1;

        for (int i = 0; i < CONV1_IN_STEPS; i = i + 1) begin
            @(posedge aclk);
            s_axis_tdata  = input_mem[i];
            s_axis_tvalid = 1'b1;
            s_axis_tlast  = (i == CONV1_IN_STEPS - 1);
            while (!s_axis_tready) @(posedge aclk);
        end

        @(posedge aclk);
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;

        while (tap_cnt[NUM_TAPS-1] < 5) @(posedge aclk);
        repeat (20) @(posedge aclk);

        total_err = 0;
        shape_err = 0;
        $display("");
        $display("  %-22s %8s %8s %8s", "tap", "beats", "expected", "wrong");
        $display("  ------------------------------------------------------");
        for (int t = 0; t < NUM_TAPS; t = t + 1) begin
            if (tap_cnt[t] != tap_len[t]) shape_err = shape_err + 1;
            total_err = total_err + tap_err[t];
            $display("  %-22s %8d %8d %8d%s", tap_name[t], tap_cnt[t], tap_len[t],
                     tap_err[t],
                     (tap_err[t] == 0 && tap_cnt[t] == tap_len[t]) ? "" : "   <-- RED");
        end
        $display("  ------------------------------------------------------");

        // Pipeline timing profile. 'span' is the number of cycles between a
        // layer's first and last output beat, i.e. how long that stage is
        // actually streaming; the largest span is the throughput bottleneck.
        $display("");
        $display("[PERF] stall_chance=%0d%%   frame latency = %0d cycles",
                 stall_chance, tap_last[NUM_TAPS-1] + 1);
        $display("  %-22s %10s %10s %10s", "tap", "first", "last", "span");
        $display("  --------------------------------------------------------");
        for (int t = 0; t < NUM_TAPS; t = t + 1) begin
            $display("  %-22s %10d %10d %10d", tap_name[t], tap_first[t], tap_last[t],
                     tap_last[t] - tap_first[t] + 1);
        end
        $display("  --------------------------------------------------------");

        // ------------------------------------------------------------------
        // CP2-3 entry measurement: per-stage AXI4-Stream handshake census.
        //
        // A stage is STARVED when its input stream shows !TVALID & TREADY (it
        // is ready, upstream has nothing) and BLOCKED when its output stream
        // shows TVALID & !TREADY (it has a result, downstream will not take
        // it). Everything else is the stage doing work or transferring.
        //
        // Read the table this way:
        //   high BLOCKED  -> this stage is throttled by what follows it;
        //   high STARVED  -> this stage is throttled by what feeds it;
        //   high BUSY     -> this stage is the rate limiter. Optimise here.
        //
        // Ping-pong result buffers only help a stage whose BLOCKED share is
        // large, so this table decides whether CP2-3 is worth building at all.
        // ------------------------------------------------------------------
        frame_cycles = tap_last[NUM_TAPS-1] + 1;
        $display("");
        $display("[PROFILE] AXI4-Stream handshake census over %0d frame cycles", frame_cycles);
        $display("  %-22s %9s %9s %9s %9s", "stage", "starved%", "blocked%", "busy%", "xfers");
        $display("  ------------------------------------------------------------------------");
        for (int s = 0; s < NUM_TAPS; s = s + 1) begin
            // Stage s consumes tap s-1 and produces tap s; stage 0 (conv1)
            // consumes the external input stream.
            if (s == 0) begin
                stage_starved = in_starved;
            end else if (s == 12) begin
                // conv6 is fed by the CP2-3 FIFO, not directly by tap 11.
                stage_starved = c6in_starved;
            end else begin
                stage_starved = hs_starved[s-1];
            end
            stage_blocked = hs_blocked[s];
            stage_busy    = frame_cycles - stage_starved - stage_blocked;
            $display("  %-22s %8.1f%% %8.1f%% %8.1f%% %9d",
                     tap_name[s],
                     100.0 * stage_starved / frame_cycles,
                     100.0 * stage_blocked / frame_cycles,
                     100.0 * stage_busy    / frame_cycles,
                     hs_xfer[s]);
        end
        $display("  ------------------------------------------------------------------------");
        $display("  input stream to conv1: %0d xfer, %0d blocked, %0d starved",
                 in_xfer, in_blocked, in_starved);
        $display("  conv6 input (after CP2-3 FIFO): %0d xfer, %0d blocked, %0d starved",
                 c6in_xfer, c6in_blocked, c6in_starved);
        $display("  conv6 input FIFO peak occupancy: %0d of %0d",
                 c6_fifo_peak, CONV6_IN_CH);
        $display("  NOTE busy%% counts compute AND transfer cycles; the stage with the");
        $display("       highest busy%% is the pipeline rate limiter.");

        $display("==================================================");
        if (total_err == 0 && shape_err == 0) begin
            $display("[PASS] All %0d layer taps bit-exact to golden, beat counts exact. [SUCCESS]",
                     NUM_TAPS);
        end else begin
            $display("[FAIL] tb_system_top_taps: %0d value errors, %0d taps with wrong beat count",
                     total_err, shape_err);
        end
        $display("==================================================");
        $finish;
    end

endmodule
