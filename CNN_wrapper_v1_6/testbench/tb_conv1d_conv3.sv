
// Hardened self-checking testbench for conv1d_stream module configured as conv3.
// Classification: Golden-Bound Math & Protocol Test

`timescale 1ns / 1ps

module tb_conv1d_conv3;

    localparam int DATA_WIDTH   = 16;
    localparam int WEIGHT_WIDTH = 16;
    localparam int IN_CHANNELS  = 16;
    localparam int OUT_CHANNELS = 32;
    localparam int KERNEL_SIZE  = 3;
    localparam int STRIDE       = 1;
    
    localparam int IN_LENGTH    = 89;
    localparam int OUT_LENGTH   = 87;
    
    localparam WEIGHT_PATH = "datasets/golden_fixed/weights_hex/conv3_weight.hex";
    localparam BIAS_PATH   = "datasets/golden_fixed/weights_hex/conv3_bias.hex";
    localparam INPUT_PATH  = "datasets/golden_fixed/test_vectors_hex/sample_0/pool1.hex";
    localparam OUTPUT_PATH = "datasets/golden_fixed/test_vectors_hex/sample_0/conv3.hex";

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

    logic [11:0]              weight_addr;
    logic [WEIGHT_WIDTH-1:0]  weight_data;
    logic [7:0]               bias_addr;
    logic [WEIGHT_WIDTH-1:0]  bias_data;

    // ROM arrays
    logic [WEIGHT_WIDTH-1:0]  weight_rom [0:IN_CHANNELS*OUT_CHANNELS*KERNEL_SIZE-1];
    logic [WEIGHT_WIDTH-1:0]  bias_rom [0:OUT_CHANNELS-1];
    logic [DATA_WIDTH-1:0]    input_mem [0:IN_LENGTH*IN_CHANNELS-1];
    logic [DATA_WIDTH-1:0]    expected_mem [0:OUT_LENGTH*OUT_CHANNELS-1];

    // Instantiate DUT
    conv1d_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .IN_CHANNELS(IN_CHANNELS),
        .OUT_CHANNELS(OUT_CHANNELS),
        .KERNEL_SIZE(KERNEL_SIZE),
        .STRIDE(STRIDE),
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
    int seed = 32'h6789ABCD;
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
                    $display("[ERROR] module=conv1d_stream, test_name=tb_conv1d_conv3, stable-under-stall failure (tvalid dropped)");
                    $finish;
                end
                if (m_axis_tdata !== prev_m_data) begin
                    $display("[ERROR] module=conv1d_stream, test_name=tb_conv1d_conv3, stable-under-stall failure (tdata changed from 0x%04H to 0x%04H)", prev_m_data, m_axis_tdata);
                    $finish;
                end
                if (m_axis_tlast !== prev_m_last) begin
                    $display("[ERROR] module=conv1d_stream, test_name=tb_conv1d_conv3, stable-under-stall failure (tlast changed)");
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
    localparam int TOTAL_OUT_BEATS = OUT_LENGTH * OUT_CHANNELS;

    // Verification monitor
    always @(posedge aclk) begin
        if (aresetn && monitor_active && prev_m_valid && prev_m_ready) begin
            logic [DATA_WIDTH-1:0] expected_data;

            expected_data = expected_mem[out_beat_cnt];

            if (prev_m_data !== expected_data) begin
                $display("[ERROR] module=conv1d_stream, test_name=tb_conv1d_conv3, transaction_index=%d, time_index=%d, channel_index=%d, expected=0x%04H, actual=0x%04H, delta=%d, cycle=%0t, seed=%0d",
                         out_beat_cnt, out_beat_cnt / OUT_CHANNELS, out_beat_cnt % OUT_CHANNELS,
                         expected_data, prev_m_data, 
                         $signed(prev_m_data) - $signed(expected_data), 
                         $time, seed);
                errors = errors + 1;
            end

            if (out_beat_cnt == TOTAL_OUT_BEATS - 1) begin
                if (!prev_m_last) begin
                    $display("[ERROR] module=conv1d_stream, test_name=tb_conv1d_conv3, missing tlast on final beat");
                    errors = errors + 1;
                end
            end else begin
                if (prev_m_last) begin
                    $display("[ERROR] module=conv1d_stream, test_name=tb_conv1d_conv3, unexpected tlast on beat %d", out_beat_cnt);
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
            $display("[BLOCKED] module=tb_conv1d_conv3, test_name=tb_conv1d_conv3, weight_path=%s, bias_path=%s, input_path=%s, expected_path=%s, missing files.",
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
            $display("[ERROR] module=conv1d_stream, test_name=tb_conv1d_conv3, reset check failed (tvalid not deasserted)");
            $finish;
        end
        aresetn <= 1;
        #10;

        $display("==================================================");
        $display("Running tb_conv1d_conv3 (Conv3 layer: 89 -> 87)...");
        $display("==================================================");

        // 2. Active frame reset check
        // Feed first 5 steps (5 * IN_CHANNELS beats)
        for (int i = 0; i < 5 * IN_CHANNELS; i = i + 1) begin
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
            $display("[ERROR] module=conv1d_stream, test_name=tb_conv1d_conv3, active mid-frame reset check failed (tvalid not deasserted)");
            $finish;
        end

        // Deassert reset and restart frame from beat 0
        @(posedge aclk);
        aresetn <= 1;
        @(posedge aclk);
        out_beat_cnt = 0;
        monitor_active = 1;

        $display("[DRV] Restarting frame from step 0...");
        // Feed IN_LENGTH * IN_CHANNELS beats
        for (int i = 0; i < IN_LENGTH * IN_CHANNELS; i = i + 1) begin
            s_axis_tdata  <= input_mem[i];
            s_axis_tvalid <= 1;
            s_axis_tlast  <= (i == IN_LENGTH * IN_CHANNELS - 1);
            @(posedge aclk);
            while (!s_axis_tready) @(posedge aclk);
        end

        s_axis_tvalid <= 0;
        s_axis_tlast <= 0;

        // Wait for monitor to process all outputs
        while (out_beat_cnt < TOTAL_OUT_BEATS) @(posedge aclk);
        #40;

        $display("==================================================");
        if (errors == 0 && out_beat_cnt == TOTAL_OUT_BEATS) begin
            $display("All tests in tb_conv1d_conv3 passed! [SUCCESS]");
        end else begin
            $display("tb_conv1d_conv3 failed with %d errors. Beat count: %d/%d [FAIL]", errors, out_beat_cnt, TOTAL_OUT_BEATS);
        end
        $display("==================================================");
        $finish;
    end

endmodule
