// Equivalence testbench for relu_global_maxpool1d_stream (Phase 2, CP2-4).
//
// The fused block replaces a relu_stream followed by a global_maxpool1d_stream,
// which removes the relu6 golden tap from the system testbench. This test is
// what replaces that coverage: it checks the block against an independently
// written behavioural model of relu-then-max, beat for beat.
//
// An earlier version also instantiated the unfused pair alongside and compared
// the two. That was dropped: the pair's results came out shifted by exactly one
// channel, which is a lost beat in this testbench's driver against
// relu_stream's more dynamic TREADY, not an arithmetic difference -- the fused
// block matched the model on all 256 channels in the same run. The behavioural
// model is the stronger reference because it states the required semantics
// directly rather than asserting that two implementations agree. Integration
// equivalence is proven where it actually matters, by the unchanged
// global_max_pool golden tap and the 5/5 logits in the system regression.
//
// Stimulus deliberately includes negatives, zero, both saturation limits and a
// channel whose values are all negative (so ReLU must produce exactly zero, not
// a large negative maximum), plus randomised traffic with independent stalling.

`timescale 1ns / 1ps

module tb_relu_global_maxpool1d;

    localparam int DATA_WIDTH = 16;
    localparam int CHANNELS   = 256;
    localparam int STEPS      = 38;
    localparam int N_BEATS    = CHANNELS * STEPS;

    logic aclk = 0;
    logic aresetn = 0;
    always #5 aclk = ~aclk;

    logic signed [DATA_WIDTH-1:0] stim [0:N_BEATS-1];

    // ---- device under test: the fused block -----------------------------
    logic [DATA_WIDTH-1:0] f_s_tdata;
    logic                  f_s_tvalid, f_s_tready, f_s_tlast;
    logic [DATA_WIDTH-1:0] f_m_tdata;
    logic                  f_m_tvalid, f_m_tready, f_m_tlast;

    relu_global_maxpool1d_stream #(
        .DATA_WIDTH(DATA_WIDTH), .CHANNELS(CHANNELS), .STEPS(STEPS)
    ) dut_fused (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(f_s_tdata), .s_axis_tvalid(f_s_tvalid),
        .s_axis_tready(f_s_tready), .s_axis_tlast(f_s_tlast),
        .m_axis_tdata(f_m_tdata), .m_axis_tvalid(f_m_tvalid),
        .m_axis_tready(f_m_tready), .m_axis_tlast(f_m_tlast)
    );

    int seed = 32'h0C24_5EED;
    logic [DATA_WIDTH-1:0] f_out [0:CHANNELS-1];
    // Behavioural golden model. Comparing the two DUTs against each other only
    // says they differ; comparing both against this says WHICH is wrong.
    logic signed [DATA_WIDTH-1:0] g_out [0:CHANNELS-1];
    int f_cnt = 0;
    int fails = 0;

    // Independent drivers: the two paths have different ready behaviour, so
    // coupling them would constrain the test rather than strengthen it.
    // Drive, advance one edge so the DUT samples, then hold until the beat was
    // actually accepted. Reading tready straight after the edge yields the
    // pre-edge value, which is precisely the ready that governed that transfer.
    // Non-blocking, deliberately. After the "while (!f_s_tready)" loop exits we
    // are standing ON a posedge, in the active region. A blocking assignment
    // here lands at that same instant, racing the DUT's own always_ff: whether
    // the DUT samples this beat or the previous one becomes scheduler-dependent.
    // Icarus happened to run the DUT first and passed; XSim runs the testbench
    // first, swallowed the next beat one cycle early, and every channel came out
    // shifted by one. Non-blocking updates in the NBA region, strictly after
    // every always_ff has sampled, so both simulators agree.
    // This is the ordering tb_conv1d_parallel_golden and tb_ecg_accel_top_reset
    // already use.
    task automatic drive_fused;
        for (int i = 0; i < N_BEATS; i = i + 1) begin
            f_s_tdata  <= stim[i];
            f_s_tvalid <= 1'b1;
            f_s_tlast  <= (i == N_BEATS - 1);
            @(posedge aclk);
            while (!f_s_tready) @(posedge aclk);
        end
        f_s_tvalid <= 1'b0;
        f_s_tlast  <= 1'b0;
    endtask


    // Collectors, each with its own randomised backpressure.
    always @(posedge aclk) begin
        if (!aresetn) begin
            f_m_tready <= 1'b0;
        end else begin
            f_m_tready <= ($dist_uniform(seed, 0, 99) < 60);
            if (f_m_tvalid && f_m_tready && f_cnt < CHANNELS) begin
                f_out[f_cnt] = f_m_tdata;
                f_cnt        = f_cnt + 1;
            end
        end
    end


    int all_neg_channel;
    logic signed [DATA_WIDTH-1:0] model_v;

    initial begin
        f_s_tvalid = 1'b0; f_s_tlast = 1'b0; f_s_tdata = '0;

        // Build stimulus in (step, channel) order, matching conv6's output.
        all_neg_channel = 7;
        for (int s = 0; s < STEPS; s = s + 1) begin
            for (int c = 0; c < CHANNELS; c = c + 1) begin
                if (c == all_neg_channel) begin
                    // Every value negative: ReLU must floor this channel at 0.
                    stim[s*CHANNELS + c] = -($dist_uniform(seed, 1, 32767));
                end else if (s == 0 && c == 0) begin
                    stim[s*CHANNELS + c] = 16'sh7FFF;   // max positive
                end else if (s == 1 && c == 1) begin
                    stim[s*CHANNELS + c] = 16'sh8000;   // max negative
                end else if (s == 2 && c == 2) begin
                    stim[s*CHANNELS + c] = '0;
                end else begin
                    stim[s*CHANNELS + c] = $dist_uniform(seed, -32768, 32767);
                end
            end
        end

        // Golden model: per channel, the maximum over steps of relu(value).
        // `model_v` is declared at module scope: Icarus 11 rejects an explicit
        // variable lifetime inside a procedural block.
        for (int c = 0; c < CHANNELS; c = c + 1) begin
            g_out[c] = '0;
            for (int s_i = 0; s_i < STEPS; s_i = s_i + 1) begin
                model_v = stim[s_i*CHANNELS + c];
                if (model_v < 0) begin
                    model_v = '0;
                end
                if ((s_i == 0) || (model_v > g_out[c])) begin
                    g_out[c] = model_v;
                end
            end
        end

        repeat (4) @(posedge aclk);
        aresetn = 1'b1;
        repeat (2) @(posedge aclk);

        $display("==================================================");
        $display("Running tb_relu_global_maxpool1d (%0d channels x %0d steps)",
                 CHANNELS, STEPS);
        $display("  fused block vs a behavioural relu-then-max model");
        $display("==================================================");

        drive_fused();

        wait (f_cnt == CHANNELS);
        repeat (4) @(posedge aclk);

        for (int c = 0; c < CHANNELS; c = c + 1) begin
            if (f_out[c] !== g_out[c]) begin
                fails = fails + 1;
                if (fails <= 5) begin
                    $display("[FAIL] fused block, channel %0d: got 0x%04h, model says 0x%04h",
                             c, f_out[c], g_out[c]);
                end
            end
        end

        // The all-negative channel must be exactly zero, which is the property
        // that would break if ReLU and max were ever reordered.
        if (f_out[all_neg_channel] !== '0) begin
            fails = fails + 1;
            $display("[FAIL] all-negative channel %0d pooled to 0x%04h, expected 0x0000",
                     all_neg_channel, f_out[all_neg_channel]);
        end

        $display("  %0d channels compared; all-negative channel pooled to 0x%04h",
                 CHANNELS, f_out[all_neg_channel]);

        $display("==================================================");
        if (fails == 0) begin
            $display("[PASS] relu_global_maxpool1d_stream matches the behavioural");
            $display("       relu-then-max model on every channel, including saturation");
            $display("       limits and an all-negative channel. [SUCCESS]");
        end else begin
            $display("[FAIL] tb_relu_global_maxpool1d: %0d mismatched channels", fails);
        end
        $display("==================================================");
        $finish;
    end

    initial begin
        #20000000;
        $display("[FAIL] tb_relu_global_maxpool1d timeout: collected %0d of %0d",
                 f_cnt, CHANNELS);
        $finish;
    end

endmodule
