// d:\fpga_cc\FPGA_CNN\rtl\tb\tb_linear_fc1.sv
// Hardened self-checking testbench for linear_layer_stream module configured as fc1.
// Classification: Golden-Bound Math & Protocol Test

`timescale 1ns / 1ps

module tb_linear_fc1;

    localparam int DATA_WIDTH   = 16;
    localparam int WEIGHT_WIDTH = 16;
    localparam int IN_FEATURES  = 256;
    localparam int OUT_FEATURES = 64;

    localparam WEIGHT_PATH = "datasets/golden_fixed/weights_hex/fc1_weight.hex";
    localparam BIAS_PATH   = "datasets/golden_fixed/weights_hex/fc1_bias.hex";
    localparam INPUT_PATH  = "datasets/golden_fixed/test_vectors_hex/sample_0/flatten.hex";
    localparam OUTPUT_PATH = "datasets/golden_fixed/test_vectors_hex/sample_0/fc1.hex";

    logic                     aclk;
    logic                     aresetn;

    logic [DATA_WIDTH-1:0]    s_axis_tdata;
    logic                     s_axis_tvalid;
    logic                     s_axis_tready;
    logic                     s_axis_tlast;

    logic [DATA_WIDTH-1:0]    m_axis_tdata;
    logic                     m_axis_tvalid;
    logic                     m_axis_tready;
    logic                     m_axis_tlast;

    logic [13:0]              weight_addr;
    logic [WEIGHT_WIDTH-1:0]  weight_data;
    logic [7:0]               bias_addr;
    logic [WEIGHT_WIDTH-1:0]  bias_data;

    // ROM arrays
    logic [WEIGHT_WIDTH-1:0]  weight_rom [0:IN_FEATURES*OUT_FEATURES-1];
    logic [WEIGHT_WIDTH-1:0]  bias_rom [0:OUT_FEATURES-1];
    logic [DATA_WIDTH-1:0]    input_mem [0:IN_FEATURES-1];
    logic [DATA_WIDTH-1:0]    expected_mem [0:OUT_FEATURES-1];

    // Instantiate DUT
    linear_layer_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .IN_FEATURES(IN_FEATURES),
        .OUT_FEATURES(OUT_FEATURES)
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
        .weight_addr(weight_addr),
        .weight_data(weight_data),
        .bias_addr(bias_addr),
        .bias_data(bias_data)
    );

    // Clock driver (10ns period)
    always #5 aclk = ~aclk;

    // Model ROMs with 1-cycle registered read latency
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            weight_data <= '0;
            bias_data   <= '0;
        end else begin
            weight_data <= weight_rom[weight_addr];
            bias_data   <= bias_rom[bias_addr];
        end
    end

    // Random backpressure seed and stall chance
    int seed = 32'h12345678;
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
                    $display("[ERROR] module=linear_layer_stream, test_name=tb_linear_fc1, stable-under-stall failure (tvalid dropped)");
                    $finish;
                end
                if (m_axis_tdata !== prev_m_data) begin
                    $display("[ERROR] module=linear_layer_stream, test_name=tb_linear_fc1, stable-under-stall failure (tdata changed from 0x%04H to 0x%04H)", prev_m_data, m_axis_tdata);
                    $finish;
                end
                if (m_axis_tlast !== prev_m_last) begin
                    $display("[ERROR] module=linear_layer_stream, test_name=tb_linear_fc1, stable-under-stall failure (tlast changed)");
                    $finish;
                end
            end
        end
        prev_m_data  <= m_axis_tdata;
        prev_m_last  <= m_axis_tlast;
        prev_m_valid <= m_axis_tvalid;
        prev_m_ready <= m_axis_tready;
    end

    int errors = 0;
    int out_beat_cnt = 0;
    logic monitor_active = 0;

    // Verification monitor
    always @(posedge aclk) begin
        if (aresetn && monitor_active && prev_m_valid && prev_m_ready) begin
            logic [DATA_WIDTH-1:0] expected_data;

            expected_data = expected_mem[out_beat_cnt];

            if (prev_m_data !== expected_data) begin
                $display("[ERROR] module=linear_layer_stream, test_name=tb_linear_fc1, transaction_index=%d, expected=0x%04H, actual=0x%04H, delta=%d, cycle=%0t, seed=%0d",
                         out_beat_cnt, expected_data, prev_m_data, 
                         $signed(prev_m_data) - $signed(expected_data), 
                         $time, seed);
                errors = errors + 1;
            end

            if (out_beat_cnt == OUT_FEATURES - 1) begin
                if (!prev_m_last) begin
                    $display("[ERROR] module=linear_layer_stream, test_name=tb_linear_fc1, missing tlast on final beat");
                    errors = errors + 1;
                end
            end else begin
                if (prev_m_last) begin
                    $display("[ERROR] module=linear_layer_stream, test_name=tb_linear_fc1, unexpected tlast on beat %d", out_beat_cnt);
                    errors = errors + 1;
                end
            end

            out_beat_cnt = out_beat_cnt + 1;
        end
    end

    // File loader with manifest checks
    int file_w, file_b, file_in, file_exp;
    initial begin
        file_w = $fopen(WEIGHT_PATH, "r");
        file_b = $fopen(BIAS_PATH, "r");
        file_in = $fopen(INPUT_PATH, "r");
        file_exp = $fopen(OUTPUT_PATH, "r");
        if (file_w == 0 || file_b == 0 || file_in == 0 || file_exp == 0) begin
            $display("[BLOCKED] module=tb_linear_fc1, test_name=tb_linear_fc1, weight_path=%s, bias_path=%s, input_path=%s, expected_path=%s, missing files.",
                     WEIGHT_PATH, BIAS_PATH, INPUT_PATH, OUTPUT_PATH);
            $finish;
        end
        $fclose(file_w);
        $fclose(file_b);
        $fclose(file_in);
        $fclose(file_exp);

        $readmemh(WEIGHT_PATH, weight_rom);
        $readmemh(BIAS_PATH, bias_rom);
        $readmemh(INPUT_PATH, input_mem);
        $readmemh(OUTPUT_PATH, expected_mem);
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
            $display("[ERROR] module=linear_layer_stream, test_name=tb_linear_fc1, reset check failed (tvalid not deasserted)");
            $finish;
        end
        aresetn <= 1;
        #10;

        $display("==================================================");
        $display("Running tb_linear_fc1 (FC1 layer: 256 -> 64)...");
        $display("==================================================");

        // 2. Active frame reset check
        // Feed first 10 features
        for (int i = 0; i < 10; i = i + 1) begin
            s_axis_tdata  <= input_mem[i];
            s_axis_tvalid <= 1;
            s_axis_tlast  <= 0;
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
            $display("[ERROR] module=linear_layer_stream, test_name=tb_linear_fc1, active mid-frame reset check failed (tvalid not cleared)");
            $finish;
        end

        // Deassert reset and restart frame from beat 0
        @(posedge aclk);
        aresetn <= 1;
        @(posedge aclk);
        out_beat_cnt = 0;
        monitor_active = 1;

        $display("[DRV] Restarting frame from feature 0...");
        // Feed 256 features (IN_FEATURES)
        for (int i = 0; i < IN_FEATURES; i = i + 1) begin
            s_axis_tdata  <= input_mem[i];
            s_axis_tvalid <= 1;
            s_axis_tlast  <= (i == IN_FEATURES - 1);
            @(posedge aclk);
            while (!s_axis_tready) @(posedge aclk);
        end

        s_axis_tvalid <= 0;
        s_axis_tlast <= 0;

        // Wait for monitor to process all outputs
        while (out_beat_cnt < OUT_FEATURES) @(posedge aclk);
        #40;

        $display("==================================================");
        if (errors == 0 && out_beat_cnt == OUT_FEATURES) begin
            $display("All tests in tb_linear_fc1 passed! [SUCCESS]");
        end else begin
            $display("tb_linear_fc1 failed with %d errors. Beat count: %d/%d [FAIL]", errors, out_beat_cnt, OUT_FEATURES);
        end
        $display("==================================================");
        $finish;
    end

endmodule
