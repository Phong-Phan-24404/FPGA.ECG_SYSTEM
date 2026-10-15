// Mid-frame reset recovery and sustained-backpressure test for ecg_accel_top.
// Phase 1, CP-6.
//
// Three properties, in one elaboration:
//
//   A. Mid-frame reset clears the stream state. The frame is abandoned halfway
//      through; after aresetn is deasserted the accelerator must present no
//      valid output and must report idle.
//   B. The frame after the reset is BIT-EXACT. A reset that leaves a partially
//      filled window buffer or a stale accumulator behind would corrupt the
//      next frame, and only a golden comparison can see that.
//   C. Sustained output backpressure drops and duplicates nothing. TREADY is
//      held low for a long stretch mid-frame; every logit must still arrive,
//      exactly once, in order, with TLAST on the last.

`timescale 1ns / 1ps

import ecg_params_pkg::*;

module tb_ecg_accel_top_reset;

    localparam int DATA_WIDTH = 16;
    localparam SAMPLE_DIR = "datasets/golden_fixed/test_vectors_hex/sample_0/";

    // How far into the input frame the abort happens, and how long TREADY is
    // held low in the backpressure phase.
    localparam int ABORT_AFTER_BEATS = 120;
    localparam int STALL_CYCLES      = 5000;

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

    logic [DATA_WIDTH-1:0] input_mem       [0:CONV1_IN_STEPS-1];
    logic [DATA_WIDTH-1:0] expected_logits [0:FC3_OUT-1];

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

    int errors        = 0;
    int out_beat_cnt  = 0;
    logic monitor_active = 1'b0;

    // Output scoreboard: order, value, TLAST position and beat count.
    always @(posedge aclk) begin
        if (aresetn && monitor_active && m_axis_tvalid && m_axis_tready) begin
            if (out_beat_cnt < FC3_OUT) begin
                if (m_axis_tdata !== expected_logits[out_beat_cnt]) begin
                    $display("[ERROR] logit %0d: expected 0x%04h, got 0x%04h",
                             out_beat_cnt, expected_logits[out_beat_cnt], m_axis_tdata);
                    errors = errors + 1;
                end
                if (((out_beat_cnt == FC3_OUT - 1) ? 1'b1 : 1'b0) !== m_axis_tlast) begin
                    $display("[ERROR] TLAST misplaced on beat %0d (tlast=%0b)",
                             out_beat_cnt, m_axis_tlast);
                    errors = errors + 1;
                end
            end else begin
                $display("[ERROR] output beat %0d beyond the expected %0d logits - duplicated frame",
                         out_beat_cnt, FC3_OUT);
                errors = errors + 1;
            end
            out_beat_cnt = out_beat_cnt + 1;
        end
    end

    // Protocol monitor: while stalled, the master must hold data and TLAST.
    logic                  stall_pending;
    logic [DATA_WIDTH-1:0] stalled_tdata;
    logic                  stalled_tlast;
    always @(posedge aclk) begin
        if (!aresetn) begin
            stall_pending <= 1'b0;
        end else begin
            if (stall_pending &&
                (!m_axis_tvalid || m_axis_tdata !== stalled_tdata ||
                 m_axis_tlast !== stalled_tlast)) begin
                $display("[ERROR] master output changed while stalled");
                errors = errors + 1;
            end
            stall_pending <= m_axis_tvalid && !m_axis_tready;
            if (m_axis_tvalid && !m_axis_tready) begin
                stalled_tdata <= m_axis_tdata;
                stalled_tlast <= m_axis_tlast;
            end
        end
    end

    // Present the beat first, THEN wait for the edge, then hold it until the
    // handshake actually completes. Waiting for the edge before presenting the
    // data means tready is sampled one cycle before the transfer, so a beat can
    // be overwritten while the DUT is still stalled - the accelerator drops
    // tready whenever conv1 leaves STATE_READ, so that happens regularly.
    // This is the ordering tb_conv1d_parallel_golden uses.
    task automatic drive_beat(input int idx, input logic last);
        begin
            s_axis_tdata  <= input_mem[idx];
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= last;
            @(posedge aclk);
            while (!s_axis_tready) @(posedge aclk);
        end
    endtask

    initial begin
        #900000000;
        $display("[FAIL] tb_ecg_accel_top_reset timeout at beat %0d/%0d",
                 out_beat_cnt, FC3_OUT);
        $finish;
    end

    initial begin
        aclk          = 0;
        aresetn       = 0;
        s_axis_tdata  = '0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        ctrl_start    = 1'b0;
        m_axis_tready = 1'b1;

        $readmemh({SAMPLE_DIR, "input.hex"},  input_mem);
        $readmemh({SAMPLE_DIR, "logits.hex"}, expected_logits);

        #20;
        aresetn = 1;
        #20;

        $display("==================================================");
        $display("Running tb_ecg_accel_top_reset");
        $display("==================================================");

        // ---------------- A. mid-frame reset ----------------------------
        $display("[TB] Phase A: abandoning a frame after %0d of %0d input beats",
                 ABORT_AFTER_BEATS, CONV1_IN_STEPS);
        @(posedge aclk);
        ctrl_start = 1'b1;
        @(posedge aclk);
        ctrl_start = 1'b0;

        for (int i = 0; i < ABORT_AFTER_BEATS; i = i + 1) begin
            drive_beat(i, 1'b0);
        end
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
        @(posedge aclk);

        @(posedge aclk);
        aresetn = 1'b0;
        repeat (8) @(posedge aclk);

        if (m_axis_tvalid !== 1'b0) begin
            $display("[ERROR] m_axis_tvalid not cleared by mid-frame reset");
            errors = errors + 1;
        end
        if (s_axis_tready !== 1'b0) begin
            $display("[ERROR] s_axis_tready not cleared by mid-frame reset");
            errors = errors + 1;
        end

        aresetn = 1'b1;
        repeat (4) @(posedge aclk);

        if (ctrl_idle !== 1'b1) begin
            $display("[ERROR] ctrl_idle is not high after reset release (got %0b)", ctrl_idle);
            errors = errors + 1;
        end
        $display("[TB] Phase A complete: stream state cleared, accelerator idle");

        // ---------------- B. the frame after the reset ------------------
        $display("[TB] Phase B: full frame after the mid-frame reset must be bit-exact");
        out_beat_cnt   = 0;
        monitor_active = 1'b1;

        @(posedge aclk);
        ctrl_start = 1'b1;
        @(posedge aclk);
        ctrl_start = 1'b0;

        for (int i = 0; i < CONV1_IN_STEPS; i = i + 1) begin
            drive_beat(i, (i == CONV1_IN_STEPS - 1));
        end
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
        @(posedge aclk);

        while (out_beat_cnt < FC3_OUT) @(posedge aclk);
        repeat (10) @(posedge aclk);
        monitor_active = 1'b0;

        if (out_beat_cnt != FC3_OUT) begin
            $display("[ERROR] Phase B produced %0d output beats, expected %0d",
                     out_beat_cnt, FC3_OUT);
            errors = errors + 1;
        end
        $display("[TB] Phase B complete: %0d/%0d logits, %0d error(s) so far",
                 out_beat_cnt, FC3_OUT, errors);

        // ---------------- C. sustained output backpressure --------------
        $display("[TB] Phase C: same frame again with TREADY held low for %0d cycles",
                 STALL_CYCLES);
        out_beat_cnt   = 0;
        monitor_active = 1'b1;

        @(posedge aclk);
        ctrl_start = 1'b1;
        @(posedge aclk);
        ctrl_start = 1'b0;

        fork
            // Input side: drive the whole frame.
            begin
                for (int i = 0; i < CONV1_IN_STEPS; i = i + 1) begin
                    drive_beat(i, (i == CONV1_IN_STEPS - 1));
                end
                s_axis_tvalid <= 1'b0;
                s_axis_tlast  <= 1'b0;
                @(posedge aclk);
            end
            // Output side: accept the first logit, then stall hard, then release.
            begin
                wait (out_beat_cnt == 1);
                m_axis_tready = 1'b0;
                $display("[TB] TREADY low after logit 0");
                repeat (STALL_CYCLES) @(posedge aclk);
                m_axis_tready = 1'b1;
                $display("[TB] TREADY released");
            end
        join

        while (out_beat_cnt < FC3_OUT) @(posedge aclk);
        repeat (20) @(posedge aclk);
        monitor_active = 1'b0;

        if (out_beat_cnt != FC3_OUT) begin
            $display("[ERROR] Phase C produced %0d output beats, expected exactly %0d",
                     out_beat_cnt, FC3_OUT);
            errors = errors + 1;
        end

        $display("==================================================");
        if (errors == 0) begin
            $display("[PASS] Mid-frame reset recovers, next frame bit-exact, sustained backpressure loses nothing. [SUCCESS]");
        end else begin
            $display("[FAIL] tb_ecg_accel_top_reset: %0d error(s)", errors);
        end
        $display("==================================================");
        $finish;
    end

endmodule
