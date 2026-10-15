// Hardened self-checking end-to-end regression testbench for ecg_accel_top.
//
// Instantiates the top wrapper with REGISTERED_MATH=1 (FULL_REAL_MATH mode) and
// drives ALL FIVE golden samples through it, comparing the 5 output logits of
// each against the golden logits.hex, bit for bit, under randomized output
// backpressure.
//
// Phase 1, CP-3: this used to run sample_0 only. One sample cannot distinguish
// a correct network from one that happens to be right on a single input — for
// example a saturation path that only this sample's dynamic range avoids. Each
// sample is preceded by a full reset, so a residual-state bug shows up as a
// wrong second frame rather than being masked.

`timescale 1ns / 1ps

import ecg_params_pkg::*;

module tb_system_top_regression;

    localparam int DATA_WIDTH  = 16;
    localparam int NUM_SAMPLES = 5;

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

    // ROM arrays to hold golden data for the sample currently under test
    logic [DATA_WIDTH-1:0] input_mem [0:CONV1_IN_STEPS-1];
    logic [DATA_WIDTH-1:0] expected_logits [0:FC3_OUT-1];

    string sample_dir;
    string input_path;
    string logits_path;

    // Instantiate DUT in FULL_REAL_MATH mode
    ecg_accel_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .REGISTERED_MATH(1) // FULL_REAL_MATH
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

    // Clock driver
    always #5 aclk = ~aclk;

    // Random backpressure seed and stall chance
    int seed = 32'hBEEF1234;
    int stall_chance = 30;

    initial begin
        if ($value$plusargs("SEED=%d", seed)) begin
            $display("[TB] Overriding seed to %0d", seed);
        end
        if ($value$plusargs("STALL_CHANCE=%d", stall_chance)) begin
            $display("[TB] Overriding stall_chance to %0d%%", stall_chance);
        end
    end

    // Master ready driver with deterministic stall
    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tready <= 1'b1;
        end else begin
            m_axis_tready <= ($dist_uniform(seed, 0, 99) >= stall_chance);
        end
    end

    // Output transaction tracking and verification
    int out_beat_cnt    = 0;
    int errors          = 0;
    int sample_errors   = 0;
    int samples_passed  = 0;
    logic monitor_active = 0;

    logic ctrl_done_latched;
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            ctrl_done_latched <= 1'b0;
        end else if (ctrl_done) begin
            ctrl_done_latched <= 1'b1;
        end
    end

    always @(posedge aclk) begin
        if (aresetn && monitor_active && m_axis_tvalid && m_axis_tready) begin
            logic signed [DATA_WIDTH-1:0] expected_val;
            logic signed [DATA_WIDTH-1:0] actual_val;

            expected_val = expected_logits[out_beat_cnt];
            actual_val   = m_axis_tdata;

            $display("[MON] %s logit %0d: 0x%04H (expected 0x%04H), tlast=%b",
                     sample_dir, out_beat_cnt, actual_val, expected_val, m_axis_tlast);

            // Bit-true comparison
            if (actual_val !== expected_val) begin
                $display("[ERROR] %s logit mismatch at index %0d! Expected 0x%04H, got 0x%04H (delta=%0d)",
                         sample_dir, out_beat_cnt, expected_val, actual_val,
                         actual_val - expected_val);
                errors        = errors + 1;
                sample_errors = sample_errors + 1;
            end

            // Check tlast on the final logit beat
            if (out_beat_cnt == FC3_OUT - 1) begin
                if (!m_axis_tlast) begin
                    $display("[ERROR] %s missing tlast assertion on final output beat!", sample_dir);
                    errors        = errors + 1;
                    sample_errors = sample_errors + 1;
                end
            end else begin
                if (m_axis_tlast) begin
                    $display("[ERROR] %s premature tlast assertion on beat %0d!",
                             sample_dir, out_beat_cnt);
                    errors        = errors + 1;
                    sample_errors = sample_errors + 1;
                end
            end

            out_beat_cnt = out_beat_cnt + 1;
        end
    end

    // Timeout watchdog, sized for five full frames of sequential math
    initial begin
        #750000000; // 750 ms  (75M clock cycles)
        $display("[FAIL] Simulation timeout during %s! Output count: %0d/%0d",
                 sample_dir, out_beat_cnt, FC3_OUT);
        $finish;
    end

    // Drive one complete frame and score it.
    task automatic run_sample(input int idx);
        int file_in, file_logits;
        begin
            sample_dir  = $sformatf("sample_%0d", idx);
            input_path  = $sformatf("datasets/golden_fixed/test_vectors_hex/%s/input.hex",
                                    sample_dir);
            logits_path = $sformatf("datasets/golden_fixed/test_vectors_hex/%s/logits.hex",
                                    sample_dir);

            file_in     = $fopen(input_path, "r");
            file_logits = $fopen(logits_path, "r");
            if (file_in == 0 || file_logits == 0) begin
                $display("[BLOCKED] Missing manifest-validated golden file for %s.", sample_dir);
                $finish;
            end
            $fclose(file_in);
            $fclose(file_logits);

            $readmemh(input_path, input_mem);
            $readmemh(logits_path, expected_logits);

            // Full reset before every sample, so a residual-state bug shows up
            // as a wrong later frame instead of being hidden by a clean start.
            monitor_active = 0;
            aresetn        = 0;
            s_axis_tvalid  = 0;
            s_axis_tlast   = 0;
            repeat (4) @(posedge aclk);
            aresetn = 1;
            repeat (2) @(posedge aclk);

            out_beat_cnt  = 0;
            sample_errors = 0;

            $display("--------------------------------------------------");
            $display("[TB] %s: driving %0d input steps", sample_dir, CONV1_IN_STEPS);

            @(posedge aclk);
            ctrl_start = 1;
            @(posedge aclk);
            ctrl_start = 0;

            monitor_active = 1;

            for (int i = 0; i < CONV1_IN_STEPS; i = i + 1) begin
                @(posedge aclk);
                s_axis_tdata  = input_mem[i];
                s_axis_tvalid = 1;
                s_axis_tlast  = (i == CONV1_IN_STEPS - 1);
                while (!s_axis_tready) @(posedge aclk);
            end

            @(posedge aclk);
            s_axis_tvalid = 0;
            s_axis_tlast  = 0;

            while (out_beat_cnt < FC3_OUT) @(posedge aclk);
            #20;
            monitor_active = 0;

            if (sample_errors == 0) begin
                samples_passed = samples_passed + 1;
                $display("[TB] %s bit-exact (5/5 logits).", sample_dir);
            end else begin
                $display("[TB] %s FAILED with %0d logit error(s).", sample_dir, sample_errors);
            end

            if (!(ctrl_done_latched && ctrl_idle)) begin
                $display("[ERROR] %s control FSM flags incorrect: done_latched=%b, idle=%b",
                         sample_dir, ctrl_done_latched, ctrl_idle);
                errors = errors + 1;
            end
        end
    endtask

    // Stimulus execution flow
    initial begin
        aclk          = 0;
        aresetn       = 0;
        s_axis_tdata  = 0;
        s_axis_tvalid = 0;
        s_axis_tlast  = 0;
        ctrl_start    = 0;
        sample_dir    = "init";

        #20;
        aresetn = 1;
        #20;

        $display("==================================================");
        $display("Running tb_system_top_regression (End-to-End, %0d samples)...", NUM_SAMPLES);
        $display("==================================================");

        for (int s = 0; s < NUM_SAMPLES; s = s + 1) begin
            run_sample(s);
        end

        $display("==================================================");
        if (errors == 0 && samples_passed == NUM_SAMPLES) begin
            $display("[PASS] End-to-End CNN math matches golden logits on %0d/%0d samples! [SUCCESS]",
                     samples_passed, NUM_SAMPLES);
            $display("[PASS] Accel FSM completed and went back to idle after every frame.");
        end else begin
            $display("[FAIL] End-to-End CNN integration failed: %0d error(s), %0d/%0d samples bit-exact.",
                     errors, samples_passed, NUM_SAMPLES);
        end
        $display("==================================================");
        $finish;
    end

endmodule
