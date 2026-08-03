
// Hardened self-checking end-to-end regression testbench for ecg_accel_top.
// Instantiates the top wrapper with REGISTERED_MATH=1 (FULL_REAL_MATH mode),
// feeds 187 input steps, and compares the final 5 output logits against PyTorch golden outputs.

`timescale 1ns / 1ps

import ecg_params_pkg::*;

module tb_system_top_regression;

    localparam int DATA_WIDTH = 16;
    
    // File paths
    localparam INPUT_PATH  = "datasets/golden_fixed/test_vectors_hex/sample_0/input.hex";
    localparam LOGITS_PATH = "datasets/golden_fixed/test_vectors_hex/sample_0/logits.hex";

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

    // ROM arrays to hold golden data
    logic [DATA_WIDTH-1:0] input_mem [0:CONV1_IN_STEPS-1];
    logic [DATA_WIDTH-1:0] expected_logits [0:FC3_OUT-1];

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
            $display("[TB] Overriding seed to %d", seed);
        end
        if ($value$plusargs("STALL_CHANCE=%d", stall_chance)) begin
            $display("[TB] Overriding stall_chance to %d%%", stall_chance);
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
    int out_beat_cnt = 0;
    int errors = 0;
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
            
            $display("[MON] Output beat %d received: 0x%04H (expected 0x%04H), tlast=%b", 
                     out_beat_cnt, actual_val, expected_val, m_axis_tlast);

            // Bit-true comparison
            if (actual_val !== expected_val) begin
                $display("[ERROR] Logit mismatch at index %d! Expected 0x%04H, got 0x%04H (delta=%d)", 
                         out_beat_cnt, expected_val, actual_val, actual_val - expected_val);
                errors = errors + 1;
            end

            // Check tlast on the final logit beat
            if (out_beat_cnt == FC3_OUT - 1) begin
                if (!m_axis_tlast) begin
                    $display("[ERROR] Missing tlast assertion on final output beat!");
                    errors = errors + 1;
                end
            end else begin
                if (m_axis_tlast) begin
                    $display("[ERROR] Unexpected premature tlast assertion on beat %d!", out_beat_cnt);
                    errors = errors + 1;
                end
            end

            out_beat_cnt = out_beat_cnt + 1;
        end
    end

    // Timeout watchdog (Large because sequential math simulates over millions of clock cycles)
    initial begin
        #150000000; // 150ms timeout (15M clock cycles)
        $display("[FAIL] Simulation timeout! Output count: %d/%d", out_beat_cnt, FC3_OUT);
        $finish;
    end

    // File loading and verification
    int file_in, file_logits;
    initial begin
        file_in = $fopen(INPUT_PATH, "r");
        file_logits = $fopen(LOGITS_PATH, "r");
        if (file_in == 0 || file_logits == 0) begin
            $display("[BLOCKED] Missing manifest-validated golden file datasets.");
            $finish;
        end
        $fclose(file_in);
        $fclose(file_logits);

        $readmemh(INPUT_PATH, input_mem);
        $readmemh(LOGITS_PATH, expected_logits);
    end

    // Stimulus execution flow
    initial begin
        aclk = 0;
        aresetn = 0;
        s_axis_tdata = 0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        ctrl_start = 0;

        #20;
        aresetn = 1;
        #20;

        $display("==================================================");
        $display("Running tb_system_top_regression (End-to-End)...");
        $display("==================================================");

        // Pulse ctrl_start
        @(posedge aclk);
        ctrl_start = 1;
        @(posedge aclk);
        ctrl_start = 0;
        
        monitor_active = 1;

        // Drive 187 input steps
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
        $display("[DRV] Finished driving input vector. Processing pipeline...");

        // Wait for all output beats to be collected
        while (out_beat_cnt < FC3_OUT) @(posedge aclk);
        
        // Wait for FSM registers to update
        #20;
        
        $display("==================================================");
        if (errors == 0 && out_beat_cnt == FC3_OUT) begin
            $display("[PASS] End-to-End CNN math matches golden logits! [SUCCESS]");
            if (ctrl_done_latched && ctrl_idle) begin
                $display("[PASS] Accel FSM completed and went back to idle.");
            end else begin
                $display("[FAIL] Control FSM flags incorrect: done_latched=%b, idle=%b", ctrl_done_latched, ctrl_idle);
            end
        end else begin
            $display("[FAIL] End-to-End CNN integration failed with %d errors. Outputs received: %d/%d", 
                     errors, out_beat_cnt, FC3_OUT);
        end
        $display("==================================================");
        $finish;
    end

endmodule
