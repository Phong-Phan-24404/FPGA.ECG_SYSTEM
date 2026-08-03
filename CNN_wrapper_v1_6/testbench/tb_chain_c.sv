// Chained self-checking testbench for Chain C: conv1d_stream (STUB) -> relu_stream -> maxpool1d_stream.
// Classification: Chained Multi-Block Scoreboard & Protocol Test (NO_MATH / Protocol)

`timescale 1ns / 1ps

module tb_chain_c;

    localparam int DATA_WIDTH   = 16;
    localparam int WEIGHT_WIDTH = 16;
    
    // conv1d parameters
    localparam int IN_CHANNELS  = 2;
    localparam int OUT_CHANNELS = 4;
    localparam int KERNEL_SIZE  = 3;
    localparam int STRIDE       = 1;
    
    // maxpool1d parameters
    localparam int POOL_K       = 2;
    localparam int POOL_S       = 2;
    localparam int POOL_IN_STEPS= 3;

    logic                     aclk;
    logic                     aresetn;

    // Chain Input
    logic [DATA_WIDTH-1:0]    s_axis_tdata;
    logic                     s_axis_tvalid;
    logic                     s_axis_tready;
    logic                     s_axis_tlast;

    // Intermediate 1: conv1d -> relu
    logic [DATA_WIDTH-1:0]    conv_out_tdata;
    logic                     conv_out_tvalid;
    logic                     conv_out_tready;
    logic                     conv_out_tlast;

    // Intermediate 2: relu -> maxpool
    logic [DATA_WIDTH-1:0]    relu_out_tdata;
    logic                     relu_out_tvalid;
    logic                     relu_out_tready;
    logic                     relu_out_tlast;

    // Chain Output
    logic [DATA_WIDTH-1:0]    m_axis_tdata;
    logic                     m_axis_tvalid;
    logic                     m_axis_tready;
    logic                     m_axis_tlast;

    // Stub weights/biases
    logic [11:0]              weight_addr;
    logic [7:0]               bias_addr;

    // Instantiate Block 1: conv1d_stream (STUB)
    conv1d_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .IN_CHANNELS(IN_CHANNELS),
        .OUT_CHANNELS(OUT_CHANNELS),
        .KERNEL_SIZE(KERNEL_SIZE),
        .STRIDE(STRIDE),
        .REGISTERED_MATH(0)
    ) i_conv (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(conv_out_tdata),
        .m_axis_tvalid(conv_out_tvalid),
        .m_axis_tready(conv_out_tready),
        .m_axis_tlast(conv_out_tlast),
        .weight_addr(weight_addr),
        .weight_data(16'h0000),
        .bias_addr(bias_addr),
        .bias_data(16'h0000)
    );

    // Instantiate Block 2: relu_stream (Registered mode)
    relu_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .REGISTERED(1)
    ) i_relu (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(conv_out_tdata),
        .s_axis_tvalid(conv_out_tvalid),
        .s_axis_tready(conv_out_tready),
        .s_axis_tlast(conv_out_tlast),
        .m_axis_tdata(relu_out_tdata),
        .m_axis_tvalid(relu_out_tvalid),
        .m_axis_tready(relu_out_tready),
        .m_axis_tlast(relu_out_tlast)
    );

    // Instantiate Block 3: maxpool1d_stream
    maxpool1d_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .CHANNELS(OUT_CHANNELS),
        .KERNEL_SIZE(POOL_K),
        .STRIDE(POOL_S),
        .IN_STEPS(POOL_IN_STEPS)
    ) i_pool (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(relu_out_tdata),
        .s_axis_tvalid(relu_out_tvalid),
        .s_axis_tready(relu_out_tready),
        .s_axis_tlast(relu_out_tlast),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast)
    );

    // Clock driver
    always #5 aclk = ~aclk;

    // Random backpressure seed and stall chance
    int seed = 32'h9C3D4E5F;
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
    // 1. Intermediate 1 Monitor
    logic [DATA_WIDTH-1:0] prev_c_data;
    logic                  prev_c_last;
    logic                  prev_c_valid;
    logic                  prev_c_ready;

    always_ff @(posedge aclk) begin
        if (aresetn) begin
            if (prev_c_valid && !prev_c_ready) begin
                if (conv_out_tvalid !== 1'b1) begin
                    $display("[ERROR] module=conv1d_stream, chain_name=chain_c, stable-under-stall failure (tvalid dropped on conv_out)");
                    $finish;
                end
                if (conv_out_tdata !== prev_c_data) begin
                    $display("[ERROR] module=conv1d_stream, chain_name=chain_c, stable-under-stall failure (tdata changed on conv_out)");
                    $finish;
                end
                if (conv_out_tlast !== prev_c_last) begin
                    $display("[ERROR] module=conv1d_stream, chain_name=chain_c, stable-under-stall failure (tlast changed on conv_out)");
                    $finish;
                end
            end
        end
        prev_c_data  <= conv_out_tdata;
        prev_c_last  <= conv_out_tlast;
        prev_c_valid <= conv_out_tvalid;
        prev_c_ready <= conv_out_tready;
    end

    // 2. Intermediate 2 Monitor
    logic [DATA_WIDTH-1:0] prev_r_data;
    logic                  prev_r_last;
    logic                  prev_r_valid;
    logic                  prev_r_ready;

    always_ff @(posedge aclk) begin
        if (aresetn) begin
            if (prev_r_valid && !prev_r_ready) begin
                if (relu_out_tvalid !== 1'b1) begin
                    $display("[ERROR] module=relu_stream, chain_name=chain_c, stable-under-stall failure (tvalid dropped on relu_out)");
                    $finish;
                end
                if (relu_out_tdata !== prev_r_data) begin
                    $display("[ERROR] module=relu_stream, chain_name=chain_c, stable-under-stall failure (tdata changed on relu_out)");
                    $finish;
                end
                if (relu_out_tlast !== prev_r_last) begin
                    $display("[ERROR] module=relu_stream, chain_name=chain_c, stable-under-stall failure (tlast changed on relu_out)");
                    $finish;
                end
            end
        end
        prev_r_data  <= relu_out_tdata;
        prev_r_last  <= relu_out_tlast;
        prev_r_valid <= relu_out_tvalid;
        prev_r_ready <= relu_out_tready;
    end

    // 3. Master Output Monitor
    logic [DATA_WIDTH-1:0] prev_m_data;
    logic                  prev_m_last;
    logic                  prev_m_valid;
    logic                  prev_m_ready;

    always_ff @(posedge aclk) begin
        if (aresetn) begin
            if (prev_m_valid && !prev_m_ready) begin
                if (m_axis_tvalid !== 1'b1) begin
                    $display("[ERROR] module=maxpool1d_stream, chain_name=chain_c, stable-under-stall failure (tvalid dropped on master)");
                    $finish;
                end
                if (m_axis_tdata !== prev_m_data) begin
                    $display("[ERROR] module=maxpool1d_stream, chain_name=chain_c, stable-under-stall failure (tdata changed on master)");
                    $finish;
                end
                if (m_axis_tlast !== prev_m_last) begin
                    $display("[ERROR] module=maxpool1d_stream, chain_name=chain_c, stable-under-stall failure (tlast changed on master)");
                    $finish;
                end
            end
        end
        prev_m_data  <= m_axis_tdata;
        prev_m_last  <= m_axis_tlast;
        prev_m_valid <= m_axis_tvalid;
        prev_m_ready <= m_axis_tready;
    end

    // Counters for scorekeeping
    int conv_beats = 0;
    int relu_beats = 0;
    int pool_beats = 0;

    always_ff @(posedge aclk) begin
        if (aresetn) begin
            if (conv_out_tvalid && conv_out_tready) conv_beats <= conv_beats + 1;
            if (relu_out_tvalid && relu_out_tready) relu_beats <= relu_beats + 1;
            if (m_axis_tvalid && m_axis_tready)    pool_beats <= pool_beats + 1;
        end
    end

    int errors = 0;
    logic monitor_active = 0;
    
    logic [DATA_WIDTH-1:0] expected_outputs [0:3];
    initial begin
        expected_outputs[0] = 16'd7;
        expected_outputs[1] = 16'd8;
        expected_outputs[2] = 16'd2;
        expected_outputs[3] = 16'd3;
    end

    // Output Scoreboard
    always @(posedge aclk) begin
        if (aresetn && monitor_active && prev_m_valid && prev_m_ready) begin
            if (prev_m_data !== expected_outputs[pool_beats-1]) begin
                $display("[ERROR] module=maxpool1d_stream, chain_name=chain_c, transaction_index=%d, expected=0x%04H, actual=0x%04H, expected_last=%b, actual_last=%b, cycle=%0t, seed=%0d",
                         pool_beats-1, expected_outputs[pool_beats-1], prev_m_data, 
                         (pool_beats-1 == 3), prev_m_last, $time, seed);
                errors = errors + 1;
            end

            if (pool_beats-1 == 3) begin
                if (!prev_m_last) begin
                    $display("[ERROR] module=maxpool1d_stream, chain_name=chain_c, missing tlast on final beat");
                    errors = errors + 1;
                end
            end else begin
                if (prev_m_last) begin
                    $display("[ERROR] module=maxpool1d_stream, chain_name=chain_c, unexpected tlast on beat %d", pool_beats-1);
                    errors = errors + 1;
                end
            end
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
        if (m_axis_tvalid !== 1'b0 || conv_out_tvalid !== 1'b0 || relu_out_tvalid !== 1'b0) begin
            $display("[ERROR] module=tb_chain_c, chain_name=chain_c, reset check failed (tvalid not deasserted)");
            $finish;
        end
        aresetn <= 1;
        #10;

        $display("==================================================");
        $display("Running tb_chain_c (conv1d -> relu -> maxpool)...");
        $display("==================================================");

        // 2. Active frame reset check
        // Feed 6 beats (3 steps)
        for (int i = 0; i < 6; i = i + 1) begin
            s_axis_tdata  <= 16'(i + 1);
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
        if (m_axis_tvalid !== 1'b0 || conv_out_tvalid !== 1'b0 || relu_out_tvalid !== 1'b0) begin
            $display("[ERROR] module=tb_chain_c, chain_name=chain_c, active mid-frame reset check failed (tvalid not cleared)");
            $finish;
        end

        // Deassert reset and restart frame from beat 0
        @(posedge aclk);
        aresetn <= 1;
        @(posedge aclk);
        conv_beats = 0;
        relu_beats = 0;
        pool_beats = 0;
        monitor_active = 1;

        $display("[DRV] Restarting frame from step 0...");
        // Feed 5 steps of input (total 10 beats)
        for (int s = 0; s < 5; s = s + 1) begin
            for (int c = 0; c < IN_CHANNELS; c = c + 1) begin
                s_axis_tdata  <= 16'(2*s + 1 + c);
                s_axis_tvalid <= 1;
                s_axis_tlast  <= (s == 4 && c == IN_CHANNELS - 1);
                @(posedge aclk);
                while (!s_axis_tready) @(posedge aclk);
            end
        end

        s_axis_tvalid <= 0;
        s_axis_tlast <= 0;

        // Wait for all output transactions to complete
        while (pool_beats < 4) @(posedge aclk);
        #100; // Allow pipeline to settle

        $display("==================================================");
        $display("Transaction Counts:");
        $display("  Conv out beats: %d (Expected: 12)", conv_beats);
        $display("  ReLU out beats: %d (Expected: 12)", relu_beats);
        $display("  Pool out beats: %d (Expected: 4)", pool_beats);
        $display("==================================================");

        if (errors == 0 && conv_beats == 12 && relu_beats == 12 && pool_beats == 4) begin
            $display("Chain C: All tests passed! [SUCCESS]");
        end else begin
            $display("Chain C failed! Errors: %d. Beats: conv=%d/12, relu=%d/12, pool=%d/4. [FAIL]",
                     errors, conv_beats, relu_beats, pool_beats);
        end
        $display("==================================================");
        $finish;
    end

endmodule
