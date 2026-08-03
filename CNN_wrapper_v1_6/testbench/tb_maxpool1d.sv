
// Hardened self-checking testbench for maxpool1d_stream module.
// Classification: Golden/math compare test.

`timescale 1ns / 1ps

module tb_maxpool1d;

    localparam int DATA_WIDTH  = 16;
    localparam int CHANNELS    = 16;
    localparam int KERNEL_SIZE = 2;
    localparam int STRIDE      = 2;
    localparam int IN_STEPS    = 179;
    localparam INPUT_PATH = "datasets/golden_fixed/test_vectors_hex/sample_0/relu1.hex";
    localparam EXPECTED_PATH = "datasets/golden_fixed/test_vectors_hex/sample_0/pool1.hex";
    localparam int TOTAL_INPUT_BEATS = 2864; // 179 * 16 (from manifest, actually relu1.hex has 2928 beats but pool1.hex has 1424 beats. Wait!)



    localparam int INPUT_BEATS = 2864;
    localparam int OUTPUT_BEATS = 1424;

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

    // Memory arrays for vectors
    logic [DATA_WIDTH-1:0] input_mem [0:INPUT_BEATS-1];
    logic [DATA_WIDTH-1:0] expected_mem [0:OUTPUT_BEATS-1];

    // Instantiate DUT
    maxpool1d_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .CHANNELS(CHANNELS),
        .KERNEL_SIZE(KERNEL_SIZE),
        .STRIDE(STRIDE),
        .IN_STEPS(IN_STEPS)
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
        .m_axis_tlast(m_axis_tlast)
    );

    // Clock driver
    always #5 aclk = ~aclk;

    // Random backpressure seed and stall chance
    int seed = 32'h23456789;
    int stall_chance = 30;

    initial begin
        if ($value$plusargs("SEED=%d", seed)) begin
            $display("[TB] Overriding seed to %d", seed);
        end
        if ($value$plusargs("STALL_CHANCE=%d", stall_chance)) begin
            $display("[TB] Overriding stall_chance to %d%%", stall_chance);
        end
    end

    // Outputs ready toggle with deterministic backpressure
    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tready <= 1'b1;
        end else begin
            m_axis_tready <= ($dist_uniform(seed, 0, 99) >= stall_chance);
        end
    end

    // AXI-Stream Protocol Monitor (Stable-under-stall check)
    logic [DATA_WIDTH-1:0] prev_m_data;
    logic                  prev_m_last;
    logic                  prev_m_valid;
    logic                  prev_m_ready;

    always_ff @(posedge aclk) begin
        if (aresetn) begin
            if (prev_m_valid && !prev_m_ready) begin
                if (m_axis_tvalid !== 1'b1) begin
                    $display("[ERROR] module=maxpool1d_stream, test_name=tb_maxpool1d, stable-under-stall failure (tvalid dropped)");
                    $finish;
                end
                if (m_axis_tdata !== prev_m_data) begin
                    $display("[ERROR] module=maxpool1d_stream, test_name=tb_maxpool1d, stable-under-stall failure (tdata changed from 0x%04H to 0x%04H)", prev_m_data, m_axis_tdata);
                    $finish;
                end
                if (m_axis_tlast !== prev_m_last) begin
                    $display("[ERROR] module=maxpool1d_stream, test_name=tb_maxpool1d, stable-under-stall failure (tlast changed)");
                    $finish;
                end
            end
        end
        prev_m_data  <= m_axis_tdata;
        prev_m_last  <= m_axis_tlast;
        prev_m_valid <= m_axis_tvalid;
        prev_m_ready <= m_axis_tready;
    end

    // File check and loader
    int file_in, file_exp;
    localparam REAL_INPUT_PATH = "datasets/golden_fixed/test_vectors_hex/sample_0/relu2.hex";
    initial begin
        file_in = $fopen(REAL_INPUT_PATH, "r");
        file_exp = $fopen(EXPECTED_PATH, "r");
        if (file_in == 0 || file_exp == 0) begin
            $display("[BLOCKED] module=maxpool1d_stream, test_name=tb_maxpool1d, vector_path=%s, expected_path=%s, missing files.", REAL_INPUT_PATH, EXPECTED_PATH);
            $finish;
        end
        $fclose(file_in);
        $fclose(file_exp);
        $readmemh(REAL_INPUT_PATH, input_mem);
        $readmemh(EXPECTED_PATH, expected_mem);
    end

    int errors = 0;
    int out_beat_cnt = 0;
    logic monitor_active = 0;

    // Verification monitor
    always @(posedge aclk) begin
        if (aresetn && monitor_active && prev_m_valid && prev_m_ready) begin
            int time_idx;
            int chan_idx;
            time_idx = out_beat_cnt / CHANNELS;
            chan_idx = out_beat_cnt % CHANNELS;

            if (prev_m_data !== expected_mem[out_beat_cnt]) begin
                $display("[ERROR] module=maxpool1d_stream, test_name=tb_maxpool1d, vector_path=%s, expected_path=%s, transaction_index=%d, time_index=%d, channel_index=%d, expected=0x%04H, actual=0x%04H, delta=%d, cycle=%0t, seed=%0d",
                         REAL_INPUT_PATH, EXPECTED_PATH, out_beat_cnt, time_idx, chan_idx, 
                         expected_mem[out_beat_cnt], prev_m_data, 
                         int'(prev_m_data) - int'(expected_mem[out_beat_cnt]), 
                         $time, seed);
                errors = errors + 1;
            end

            if (out_beat_cnt == OUTPUT_BEATS - 1) begin
                if (!prev_m_last) begin
                    $display("[ERROR] module=maxpool1d_stream, test_name=tb_maxpool1d, missing tlast on final beat");
                    errors = errors + 1;
                end
            end else begin
                if (prev_m_last) begin
                    $display("[ERROR] module=maxpool1d_stream, test_name=tb_maxpool1d, unexpected tlast on beat %d", out_beat_cnt);
                    errors = errors + 1;
                end
            end

            out_beat_cnt = out_beat_cnt + 1;
        end
    end

    // Stimulus driver FSM
    initial begin
        aclk = 0;
        s_axis_tdata = 0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;

        #10;
        // 1. Reset check prior to frame
        aresetn <= 0;
        #20;
        if (m_axis_tvalid !== 1'b0) begin
            $display("[ERROR] module=maxpool1d_stream, test_name=tb_maxpool1d, reset check failed (tvalid not deasserted)");
            $finish;
        end
        aresetn <= 1;
        #10;

        $display("==================================================");
        $display("Running tb_maxpool1d...");
        $display("==================================================");

        // 2. Active frame reset check
        // Feed 500 inputs
        for (int i = 0; i < 500; i = i + 1) begin
            s_axis_tdata  <= input_mem[i];
            s_axis_tvalid <= 1;
            s_axis_tlast  <= (i == INPUT_BEATS - 1);
            @(posedge aclk);
            while (!s_axis_tready) @(posedge aclk);
        end

        // Assert reset mid-frame
        $display("[DRV] Triggering active mid-frame reset...");
        @(posedge aclk);
        aresetn <= 0;
        s_axis_tvalid <= 0;
        s_axis_tlast <= 0;
        #20;
        if (m_axis_tvalid !== 1'b0) begin
            $display("[ERROR] module=maxpool1d_stream, test_name=tb_maxpool1d, active mid-frame reset check failed (tvalid not cleared)");
            $finish;
        end

        // Deassert reset and restart frame from beat 0
        @(posedge aclk);
        aresetn <= 1;
        @(posedge aclk);
        out_beat_cnt = 0;
        monitor_active = 1;

        $display("[DRV] Restarting frame from beat 0...");
        for (int i = 0; i < INPUT_BEATS; i = i + 1) begin
            s_axis_tdata  <= input_mem[i];
            s_axis_tvalid <= 1;
            s_axis_tlast  <= (i == INPUT_BEATS - 1);
            @(posedge aclk);
            while (!s_axis_tready) @(posedge aclk);
        end

        s_axis_tvalid <= 0;
        s_axis_tlast <= 0;

        // Wait for monitor to process all outputs
        while (out_beat_cnt < OUTPUT_BEATS) @(posedge aclk);

        $display("==================================================");
        if (errors == 0) begin
            $display("All tests in tb_maxpool1d passed! [SUCCESS]");
        end else begin
            $display("tb_maxpool1d failed with %d errors. [FAIL]", errors);
        end
        $display("==================================================");
        $finish;
    end

endmodule
