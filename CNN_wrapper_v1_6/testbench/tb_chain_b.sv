// Chained self-checking testbench for Chain B: maxpool1d_stream -> relu_stream.
// Classification: Chained Multi-Block Scoreboard & Protocol Test

`timescale 1ns / 1ps

module tb_chain_b;

    localparam int DATA_WIDTH  = 16;
    localparam int CHANNELS    = 16;
    localparam int KERNEL_SIZE = 2;
    localparam int STRIDE      = 2;
    localparam int IN_STEPS    = 179;

    localparam INPUT_PATH = "datasets/golden_fixed/test_vectors_hex/sample_0/relu2.hex";
    localparam EXPECTED_PATH = "datasets/golden_fixed/test_vectors_hex/sample_0/pool1.hex";

    localparam int INPUT_BEATS = 2864;  // 179 steps * 16 channels
    localparam int OUTPUT_BEATS = 1424; // 89 steps * 16 channels

    logic                  aclk;
    logic                  aresetn;

    // Chain Input
    logic [DATA_WIDTH-1:0] s_axis_tdata;
    logic                  s_axis_tvalid;
    logic                  s_axis_tready;
    logic                  s_axis_tlast;

    // Intermediate Signals
    logic [DATA_WIDTH-1:0] pool_out_tdata;
    logic                  pool_out_tvalid;
    logic                  pool_out_tready;
    logic                  pool_out_tlast;

    // Chain Output
    logic [DATA_WIDTH-1:0] m_axis_tdata;
    logic                  m_axis_tvalid;
    logic                  m_axis_tready;
    logic                  m_axis_tlast;

    // Memory arrays for vectors
    logic [DATA_WIDTH-1:0] input_mem [0:INPUT_BEATS-1];
    logic [DATA_WIDTH-1:0] expected_mem [0:OUTPUT_BEATS-1];

    // Instantiate Block 1: maxpool1d_stream
    maxpool1d_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .CHANNELS(CHANNELS),
        .KERNEL_SIZE(KERNEL_SIZE),
        .STRIDE(STRIDE),
        .IN_STEPS(IN_STEPS)
    ) i_pool (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(pool_out_tdata),
        .m_axis_tvalid(pool_out_tvalid),
        .m_axis_tready(pool_out_tready),
        .m_axis_tlast(pool_out_tlast)
    );

    // Instantiate Block 2: relu_stream (Registered mode)
    relu_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .REGISTERED(1)
    ) i_relu (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(pool_out_tdata),
        .s_axis_tvalid(pool_out_tvalid),
        .s_axis_tready(pool_out_tready),
        .s_axis_tlast(pool_out_tlast),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast)
    );

    // Clock driver (10ns period)
    always #5 aclk = ~aclk;

    // Random backpressure seed and stall chance
    int seed = 32'h8B2C3D4E;
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

    // AXI-Stream Protocol Monitor (Stable-under-stall checks)
    // 1. Intermediate Port Monitor
    logic [DATA_WIDTH-1:0] prev_i_data;
    logic                  prev_i_last;
    logic                  prev_i_valid;
    logic                  prev_i_ready;

    always_ff @(posedge aclk) begin
        if (aresetn) begin
            if (prev_i_valid && !prev_i_ready) begin
                if (pool_out_tvalid !== 1'b1) begin
                    $display("[ERROR] module=maxpool1d_stream, chain_name=chain_b, stable-under-stall failure (tvalid dropped on intermediate)");
                    $finish;
                end
                if (pool_out_tdata !== prev_i_data) begin
                    $display("[ERROR] module=maxpool1d_stream, chain_name=chain_b, stable-under-stall failure (tdata changed on intermediate)");
                    $finish;
                end
                if (pool_out_tlast !== prev_i_last) begin
                    $display("[ERROR] module=maxpool1d_stream, chain_name=chain_b, stable-under-stall failure (tlast changed on intermediate)");
                    $finish;
                end
            end
        end
        prev_i_data  <= pool_out_tdata;
        prev_i_last  <= pool_out_tlast;
        prev_i_valid <= pool_out_tvalid;
        prev_i_ready <= pool_out_tready;
    end

    // 2. Master Port Monitor
    logic [DATA_WIDTH-1:0] prev_m_data;
    logic                  prev_m_last;
    logic                  prev_m_valid;
    logic                  prev_m_ready;

    always_ff @(posedge aclk) begin
        if (aresetn) begin
            if (prev_m_valid && !prev_m_ready) begin
                if (m_axis_tvalid !== 1'b1) begin
                    $display("[ERROR] module=relu_stream, chain_name=chain_b, stable-under-stall failure (tvalid dropped on master)");
                    $finish;
                end
                if (m_axis_tdata !== prev_m_data) begin
                    $display("[ERROR] module=relu_stream, chain_name=chain_b, stable-under-stall failure (tdata changed on master from 0x%04H to 0x%04H)", prev_m_data, m_axis_tdata);
                    $finish;
                end
                if (m_axis_tlast !== prev_m_last) begin
                    $display("[ERROR] module=relu_stream, chain_name=chain_b, stable-under-stall failure (tlast changed on master)");
                    $finish;
                end
            end
        end
        prev_m_data  <= m_axis_tdata;
        prev_m_last  <= m_axis_tlast;
        prev_m_valid <= m_axis_tvalid;
        prev_m_ready <= m_axis_tready;
    end

    // File loader
    int file_in, file_exp;
    initial begin
        file_in = $fopen(INPUT_PATH, "r");
        file_exp = $fopen(EXPECTED_PATH, "r");
        if (file_in == 0 || file_exp == 0) begin
            $display("[BLOCKED] module=tb_chain_b, test_name=tb_chain_b, vector_path=%s, expected_path=%s, missing files.", INPUT_PATH, EXPECTED_PATH);
            $finish;
        end
        $fclose(file_in);
        $fclose(file_exp);
        $readmemh(INPUT_PATH, input_mem);
        $readmemh(EXPECTED_PATH, expected_mem);
    end

    int errors = 0;
    int out_beat_cnt = 0;
    logic monitor_active = 0;

    // Scoreboard Checker
    always @(posedge aclk) begin
        if (aresetn && monitor_active && prev_m_valid && prev_m_ready) begin
            if (prev_m_data !== expected_mem[out_beat_cnt]) begin
                $display("[ERROR] module=relu_stream, chain_name=chain_b, transaction_index=%d, expected=0x%04H, actual=0x%04H, expected_last=%b, actual_last=%b, cycle=%0t, seed=%0d",
                         out_beat_cnt, expected_mem[out_beat_cnt], prev_m_data, 
                         (out_beat_cnt == OUTPUT_BEATS - 1), prev_m_last, $time, seed);
                errors = errors + 1;
            end

            if (out_beat_cnt == OUTPUT_BEATS - 1) begin
                if (!prev_m_last) begin
                    $display("[ERROR] module=relu_stream, chain_name=chain_b, missing tlast on final beat");
                    errors = errors + 1;
                end
            end else begin
                if (prev_m_last) begin
                    $display("[ERROR] module=relu_stream, chain_name=chain_b, unexpected tlast on beat %d", out_beat_cnt);
                    errors = errors + 1;
                end
            end

            out_beat_cnt = out_beat_cnt + 1;
        end
    end

    // Stimulus Driver
    initial begin
        aclk = 0;
        s_axis_tdata = 0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;

        #10;
        // 1. Reset check prior to frame
        aresetn <= 0;
        #20;
        if (m_axis_tvalid !== 1'b0 || pool_out_tvalid !== 1'b0) begin
            $display("[ERROR] module=tb_chain_b, chain_name=chain_b, reset check failed (tvalid not deasserted)");
            $finish;
        end
        aresetn <= 1;
        #10;

        $display("==================================================");
        $display("Running tb_chain_b (maxpool1d_stream -> relu_stream)...");
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
        if (m_axis_tvalid !== 1'b0 || pool_out_tvalid !== 1'b0) begin
            $display("[ERROR] module=tb_chain_b, chain_name=chain_b, active mid-frame reset check failed (tvalid not cleared)");
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
        if (errors == 0 && out_beat_cnt == OUTPUT_BEATS) begin
            $display("Chain B: All tests passed! [SUCCESS]");
        end else begin
            $display("Chain B failed with %d errors. Beat count: %d/%d. [FAIL]", errors, out_beat_cnt, OUTPUT_BEATS);
        end
        $display("==================================================");
        $finish;
    end

endmodule
