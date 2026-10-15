// Golden regression harness for linear_layer_parallel_stream.
// Reads the original scalar weight file and independently creates the packed
// one-cycle-latency PAR_OUT vector, so the RTL and offline repacker are checked
// independently.

`timescale 1ns / 1ps

module tb_linear_parallel_golden #(
    parameter int DATA_WIDTH        = 16,
    parameter int WEIGHT_WIDTH      = 16,
    parameter int IN_FEATURES       = 256,
    parameter int OUT_FEATURES      = 64,
    parameter int PAR_OUT           = 16,
    parameter int WEIGHT_ADDR_WIDTH = 10,
    parameter WEIGHT_PATH           = "datasets/golden_fixed/weights_hex/fc1_weight.hex",
    parameter BIAS_PATH             = "datasets/golden_fixed/weights_hex/fc1_bias.hex",
    parameter INPUT_PATH            = "datasets/golden_fixed/test_vectors_hex/sample_0/flatten.hex",
    parameter OUTPUT_PATH           = "datasets/golden_fixed/test_vectors_hex/sample_0/fc1.hex",
    parameter TEST_NAME             = "tb_linear_parallel_golden",
    parameter int MAX_FRAME_CYCLES  = 200000
);

    localparam int OUT_GROUPS    = OUT_FEATURES / PAR_OUT;
    localparam int TOTAL_WEIGHTS = IN_FEATURES * OUT_FEATURES;

    logic aclk;
    logic aresetn;

    logic [DATA_WIDTH-1:0] s_axis_tdata;
    logic                  s_axis_tvalid;
    logic                  s_axis_tready;
    logic                  s_axis_tlast;

    logic [DATA_WIDTH-1:0] m_axis_tdata;
    logic                  m_axis_tvalid;
    logic                  m_axis_tready;
    logic                  m_axis_tlast;

    logic [WEIGHT_ADDR_WIDTH-1:0]    weight_addr;
    logic [PAR_OUT*WEIGHT_WIDTH-1:0] weight_data_vec;
    logic [7:0]                      bias_addr;
    logic [WEIGHT_WIDTH-1:0]         bias_data;

    logic [WEIGHT_WIDTH-1:0] weight_rom [0:TOTAL_WEIGHTS-1];
    logic [WEIGHT_WIDTH-1:0] bias_rom [0:OUT_FEATURES-1];
    logic [DATA_WIDTH-1:0] input_mem [0:IN_FEATURES-1];
    logic [DATA_WIDTH-1:0] expected_mem [0:OUT_FEATURES-1];

    linear_layer_parallel_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .IN_FEATURES(IN_FEATURES),
        .OUT_FEATURES(OUT_FEATURES),
        .PAR_OUT(PAR_OUT),
        .WEIGHT_ADDR_WIDTH(WEIGHT_ADDR_WIDTH)
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
        .weight_data_vec(weight_data_vec),
        .bias_addr(bias_addr),
        .bias_data(bias_data)
    );

    always #5 aclk = ~aclk;

    integer lane_i;
    integer packed_group;
    integer packed_feature;
    integer scalar_index;
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            weight_data_vec <= '0;
        end else if (weight_addr < OUT_GROUPS * IN_FEATURES) begin
            packed_group   = weight_addr / IN_FEATURES;
            packed_feature = weight_addr % IN_FEATURES;
            for (lane_i = 0; lane_i < PAR_OUT; lane_i = lane_i + 1) begin
                scalar_index =
                    (packed_group * PAR_OUT + lane_i) * IN_FEATURES
                    + packed_feature;
                weight_data_vec[lane_i*WEIGHT_WIDTH +: WEIGHT_WIDTH]
                    <= weight_rom[scalar_index];
            end
        end else begin
            weight_data_vec <= '0;
        end
    end

    // The optimized top uses asynchronous distributed bias ROMs for fc1/fc2.
    always_comb begin
        bias_data = bias_rom[bias_addr];
    end

    int seed = 32'h2468ACE1;
    int stall_chance = 30;
    initial begin
        if ($value$plusargs("SEED=%d", seed)) begin
            $display("[TB] %s seed=%0d", TEST_NAME, seed);
        end
        if ($value$plusargs("STALL_CHANCE=%d", stall_chance)) begin
            $display("[TB] %s stall=%0d%%", TEST_NAME, stall_chance);
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tready <= 1'b1;
        end else begin
            m_axis_tready <= ($dist_uniform(seed, 0, 99) >= stall_chance);
        end
    end

    int errors = 0;
    int out_beat_cnt = 0;
    int frame_cycles = 0;
    logic monitor_active = 1'b0;
    logic timer_active = 1'b0;

    logic stall_holding;
    logic [DATA_WIDTH-1:0] held_data;
    logic held_last;
    always @(posedge aclk) begin
        if (!aresetn) begin
            stall_holding <= 1'b0;
            held_data <= '0;
            held_last <= 1'b0;
        end else begin
            if (stall_holding) begin
                if (m_axis_tvalid !== 1'b1) begin
                    $display("[ERROR] %s tvalid dropped while stalled", TEST_NAME);
                    errors = errors + 1;
                end
                if (m_axis_tdata !== held_data) begin
                    $display("[ERROR] %s tdata changed while stalled", TEST_NAME);
                    errors = errors + 1;
                end
                if (m_axis_tlast !== held_last) begin
                    $display("[ERROR] %s tlast changed while stalled", TEST_NAME);
                    errors = errors + 1;
                end
            end
            if (m_axis_tvalid && !m_axis_tready) begin
                stall_holding <= 1'b1;
                held_data <= m_axis_tdata;
                held_last <= m_axis_tlast;
            end else begin
                stall_holding <= 1'b0;
            end
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            frame_cycles = 0;
        end else if (timer_active) begin
            frame_cycles = frame_cycles + 1;
            if (frame_cycles > MAX_FRAME_CYCLES) begin
                $display("[FAIL] %s exceeded MAX_FRAME_CYCLES=%0d", TEST_NAME, MAX_FRAME_CYCLES);
                $finish;
            end
        end

        if (aresetn && monitor_active && m_axis_tvalid && m_axis_tready) begin
            if (out_beat_cnt >= OUT_FEATURES) begin
                $display("[ERROR] %s extra output beat", TEST_NAME);
                errors = errors + 1;
            end else begin
                if (m_axis_tdata !== expected_mem[out_beat_cnt]) begin
                    $display("[ERROR] %s beat=%0d expected=0x%04H actual=0x%04H delta=%0d",
                             TEST_NAME, out_beat_cnt, expected_mem[out_beat_cnt], m_axis_tdata,
                             $signed(m_axis_tdata) - $signed(expected_mem[out_beat_cnt]));
                    errors = errors + 1;
                end
                if ((out_beat_cnt == OUT_FEATURES - 1) != (m_axis_tlast === 1'b1)) begin
                    $display("[ERROR] %s TLAST mismatch at beat=%0d", TEST_NAME, out_beat_cnt);
                    errors = errors + 1;
                end
            end
            out_beat_cnt = out_beat_cnt + 1;
        end
    end

    int file_w;
    int file_b;
    int file_in;
    int file_exp;
    initial begin
        file_w = $fopen(WEIGHT_PATH, "r");
        file_b = $fopen(BIAS_PATH, "r");
        file_in = $fopen(INPUT_PATH, "r");
        file_exp = $fopen(OUTPUT_PATH, "r");
        if (file_w == 0 || file_b == 0 || file_in == 0 || file_exp == 0) begin
            $display("[BLOCKED] %s missing golden dataset file(s)", TEST_NAME);
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

    task automatic drive_beat(input int beat_index, input logic mark_last);
        begin
            s_axis_tdata <= input_mem[beat_index];
            s_axis_tvalid <= 1'b1;
            s_axis_tlast <= mark_last;
            @(posedge aclk);
            while (!s_axis_tready) begin
                @(posedge aclk);
            end
        end
    endtask

    initial begin
        aclk = 1'b0;
        aresetn = 1'b0;
        s_axis_tdata = '0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast = 1'b0;
        m_axis_tready = 1'b1;

        if ((OUT_FEATURES % PAR_OUT) != 0) begin
            $display("[FAIL] %s OUT_FEATURES %% PAR_OUT != 0", TEST_NAME);
            $finish;
        end

        #30;
        aresetn = 1'b1;
        repeat (2) @(posedge aclk);

        // Active-frame reset, then restart from feature 0.
        for (int i = 0; i < 8; i = i + 1) begin
            drive_beat(i, 1'b0);
        end
        s_axis_tvalid <= 1'b0;
        @(posedge aclk);
        aresetn <= 1'b0;
        repeat (3) @(posedge aclk);
        if (m_axis_tvalid !== 1'b0) begin
            $display("[FAIL] %s output valid remained asserted after reset", TEST_NAME);
            $finish;
        end
        aresetn <= 1'b1;
        repeat (2) @(posedge aclk);

        @(negedge aclk);
        out_beat_cnt = 0;
        errors = 0;
        frame_cycles = 0;
        monitor_active = 1'b1;
        timer_active = 1'b1;

        for (int i = 0; i < IN_FEATURES; i = i + 1) begin
            drive_beat(i, (i == IN_FEATURES - 1));
        end
        s_axis_tvalid <= 1'b0;
        s_axis_tlast <= 1'b0;

        while (out_beat_cnt < OUT_FEATURES) begin
            @(posedge aclk);
            #1;
        end
        @(negedge aclk);
        timer_active = 1'b0;
        repeat (5) @(posedge aclk);

        $display("[PERF] %s completed frame in %0d cycles with %0d%% stall", TEST_NAME,
                 frame_cycles, stall_chance);
        if (errors == 0 && out_beat_cnt == OUT_FEATURES) begin
            $display("[PASS] %s parallel linear RTL is bit-exact and AXI stall-safe [SUCCESS]", TEST_NAME);
        end else begin
            $display("[FAIL] %s errors=%0d beats=%0d/%0d", TEST_NAME, errors,
                     out_beat_cnt, OUT_FEATURES);
        end
        $finish;
    end

endmodule
