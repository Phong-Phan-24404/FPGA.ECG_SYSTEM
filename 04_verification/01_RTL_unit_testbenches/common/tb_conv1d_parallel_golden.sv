// Self-checking golden regression for conv1d_parallel_stream.
// The TB intentionally reads the ORIGINAL scalar weight file and constructs the
// packed PAR_OUT-wide, one-cycle-latency weight vector on the fly. This makes
// the test independent of the offline repack script and directly checks that
// the new parallel engine is bit-exact against the existing golden vectors.

`timescale 1ns / 1ps

module tb_conv1d_parallel_golden #(
    parameter int DATA_WIDTH        = 16,
    parameter int WEIGHT_WIDTH      = 16,
    parameter int IN_CHANNELS       = 32,
    parameter int OUT_CHANNELS      = 32,
    parameter int KERNEL_SIZE       = 3,
    parameter int STRIDE            = 1,
    parameter int PAR_OUT           = 2,
    parameter int K_PAR             = 1,
    parameter int WEIGHT_ADDR_WIDTH = 11,
    parameter int IN_LENGTH         = 87,
    parameter int OUT_LENGTH        = 85,
    parameter WEIGHT_PATH           = "datasets/golden_fixed/weights_hex/conv4_weight.hex",
    parameter BIAS_PATH             = "datasets/golden_fixed/weights_hex/conv4_bias.hex",
    parameter INPUT_PATH            = "datasets/golden_fixed/test_vectors_hex/sample_0/relu3.hex",
    parameter OUTPUT_PATH           = "datasets/golden_fixed/test_vectors_hex/sample_0/conv4.hex",
    parameter TEST_NAME             = "tb_conv1d_parallel_golden",
    parameter int ACTIVE_RESET_STEPS = 5,
    parameter int MAX_FRAME_CYCLES   = 2000000
);

    localparam int TERMS           = IN_CHANNELS * KERNEL_SIZE;
    localparam int K_GROUPS        = KERNEL_SIZE / K_PAR;
    localparam int ISSUE_TERMS     = IN_CHANNELS * K_GROUPS;
    localparam int OUT_GROUPS      = OUT_CHANNELS / PAR_OUT;
    localparam int TOTAL_WEIGHTS   = OUT_CHANNELS * TERMS;
    localparam int TOTAL_IN_BEATS  = IN_LENGTH * IN_CHANNELS;
    localparam int TOTAL_OUT_BEATS = OUT_LENGTH * OUT_CHANNELS;

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

    logic [WEIGHT_ADDR_WIDTH-1:0]     weight_addr;
    logic [PAR_OUT*K_PAR*WEIGHT_WIDTH-1:0] weight_data_vec;
    logic [7:0]                       bias_addr;
    logic [WEIGHT_WIDTH-1:0]          bias_data;

    logic [WEIGHT_WIDTH-1:0] weight_rom [0:TOTAL_WEIGHTS-1];
    logic [WEIGHT_WIDTH-1:0] bias_rom [0:OUT_CHANNELS-1];
    logic [DATA_WIDTH-1:0]   input_mem [0:TOTAL_IN_BEATS-1];
    logic [DATA_WIDTH-1:0]   expected_mem [0:TOTAL_OUT_BEATS-1];

    conv1d_parallel_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .IN_CHANNELS(IN_CHANNELS),
        .OUT_CHANNELS(OUT_CHANNELS),
        .KERNEL_SIZE(KERNEL_SIZE),
        .STRIDE(STRIDE),
        .PAR_OUT(PAR_OUT),
        .K_PAR(K_PAR),
        .REGISTERED_MATH(1),
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

    // Match the synthesized packed BRAM behavior: one-cycle registered read.
    // The source file stays scalar, so this TB also independently checks the
    // lane/address mapping expected by conv1d_parallel_stream.
    integer lane_i;
    integer kp_i;
    integer packed_group;
    integer packed_issue;
    integer packed_ic;
    integer packed_kg;
    integer scalar_index;
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            weight_data_vec <= '0;
        end else if (weight_addr < OUT_GROUPS * ISSUE_TERMS) begin
            packed_group = weight_addr / ISSUE_TERMS;
            packed_issue = weight_addr % ISSUE_TERMS;
            packed_ic    = packed_issue / K_GROUPS;
            packed_kg    = packed_issue % K_GROUPS;
            for (lane_i = 0; lane_i < PAR_OUT; lane_i = lane_i + 1) begin
                for (kp_i = 0; kp_i < K_PAR; kp_i = kp_i + 1) begin
                    scalar_index =
                        ((packed_group * PAR_OUT + lane_i) * TERMS)
                        + packed_ic * KERNEL_SIZE
                        + packed_kg * K_PAR
                        + kp_i;
                    weight_data_vec[((lane_i*K_PAR + kp_i)*WEIGHT_WIDTH) +: WEIGHT_WIDTH]
                        <= weight_rom[scalar_index];
                end
            end
        end else begin
            weight_data_vec <= '0;
        end
    end

    // Optimized top uses asynchronous distributed ROM for Conv4/5/6 biases.
    always_comb begin
        bias_data = bias_rom[bias_addr];
    end

    int seed = 32'h13579BDF;
    int stall_chance = 30;
    initial begin
        if ($value$plusargs("SEED=%d", seed)) begin
            $display("[TB] %s overriding seed to %0d", TEST_NAME, seed);
        end
        if ($value$plusargs("STALL_CHANCE=%d", stall_chance)) begin
            $display("[TB] %s overriding stall chance to %0d%%", TEST_NAME, stall_chance);
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
    logic frame_timer_active = 1'b0;

    // AXI output must remain stable while stalled.
    logic stall_holding;
    logic [DATA_WIDTH-1:0] held_data;
    logic held_last;
    // Plain always, not always_ff: this block increments `errors`, which the
    // scoreboard below and the stimulus initial block also write. Vivado XSim
    // rejects that as
    //   ERROR: [VRFC 10-3818] variable 'errors' is driven by invalid
    //   combination of procedural drivers
    // because a variable assigned inside always_ff may not be assigned by any
    // other process. Icarus accepts it, which is why this only surfaced under
    // XSim (Phase 1, CP-7). Nothing here is synthesized, so always_ff bought
    // nothing.
    always @(posedge aclk) begin
        if (!aresetn) begin
            stall_holding <= 1'b0;
            held_data     <= '0;
            held_last     <= 1'b0;
        end else begin
            if (stall_holding) begin
                if (m_axis_tvalid !== 1'b1) begin
                    $display("[ERROR] %s: tvalid dropped while stalled", TEST_NAME);
                    errors = errors + 1;
                end
                if (m_axis_tdata !== held_data) begin
                    $display("[ERROR] %s: tdata changed while stalled: held=0x%04H now=0x%04H",
                             TEST_NAME, held_data, m_axis_tdata);
                    errors = errors + 1;
                end
                if (m_axis_tlast !== held_last) begin
                    $display("[ERROR] %s: tlast changed while stalled", TEST_NAME);
                    errors = errors + 1;
                end
            end

            if (m_axis_tvalid && !m_axis_tready) begin
                stall_holding <= 1'b1;
                held_data     <= m_axis_tdata;
                held_last     <= m_axis_tlast;
            end else begin
                stall_holding <= 1'b0;
            end
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            frame_cycles = 0;
        end else if (frame_timer_active) begin
            frame_cycles = frame_cycles + 1;
            if (frame_cycles > MAX_FRAME_CYCLES) begin
                $display("[FAIL] %s exceeded MAX_FRAME_CYCLES=%0d", TEST_NAME, MAX_FRAME_CYCLES);
                $finish;
            end
        end

        if (aresetn && monitor_active && m_axis_tvalid && m_axis_tready) begin
            if (out_beat_cnt >= TOTAL_OUT_BEATS) begin
                $display("[ERROR] %s produced extra output beat 0x%04H", TEST_NAME, m_axis_tdata);
                errors = errors + 1;
            end else begin
                if (m_axis_tdata !== expected_mem[out_beat_cnt]) begin
                    $display("[ERROR] %s beat=%0d time=%0d ch=%0d expected=0x%04H actual=0x%04H delta=%0d",
                             TEST_NAME,
                             out_beat_cnt,
                             out_beat_cnt / OUT_CHANNELS,
                             out_beat_cnt % OUT_CHANNELS,
                             expected_mem[out_beat_cnt],
                             m_axis_tdata,
                             $signed(m_axis_tdata) - $signed(expected_mem[out_beat_cnt]));
                    errors = errors + 1;
                end

                if (out_beat_cnt == TOTAL_OUT_BEATS - 1) begin
                    if (!m_axis_tlast) begin
                        $display("[ERROR] %s missing tlast on final beat", TEST_NAME);
                        errors = errors + 1;
                    end
                end else if (m_axis_tlast) begin
                    $display("[ERROR] %s premature tlast on beat %0d", TEST_NAME, out_beat_cnt);
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
        file_w   = $fopen(WEIGHT_PATH, "r");
        file_b   = $fopen(BIAS_PATH, "r");
        file_in  = $fopen(INPUT_PATH, "r");
        file_exp = $fopen(OUTPUT_PATH, "r");
        if (file_w == 0 || file_b == 0 || file_in == 0 || file_exp == 0) begin
            $display("[BLOCKED] %s missing golden dataset file(s)", TEST_NAME);
            $display("          weight=%s", WEIGHT_PATH);
            $display("          bias=%s", BIAS_PATH);
            $display("          input=%s", INPUT_PATH);
            $display("          expected=%s", OUTPUT_PATH);
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
            s_axis_tdata  <= input_mem[beat_index];
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= mark_last;
            @(posedge aclk);
            while (!s_axis_tready) begin
                @(posedge aclk);
            end
        end
    endtask

    initial begin
        aclk          = 1'b0;
        aresetn       = 1'b0;
        s_axis_tdata  = '0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        m_axis_tready = 1'b1;

        if ((OUT_CHANNELS % PAR_OUT) != 0) begin
            $display("[FAIL] %s invalid parameters: OUT_CHANNELS %% PAR_OUT != 0", TEST_NAME);
            $finish;
        end
        if ((KERNEL_SIZE % K_PAR) != 0) begin
            $display("[FAIL] %s invalid parameters: KERNEL_SIZE %% K_PAR != 0", TEST_NAME);
            $finish;
        end

        #30;
        if (m_axis_tvalid !== 1'b0) begin
            $display("[FAIL] %s m_axis_tvalid asserted during reset", TEST_NAME);
            $finish;
        end
        aresetn = 1'b1;
        repeat (2) @(posedge aclk);

        $display("==================================================");
        $display("Running %s: IN_CH=%0d OUT_CH=%0d K=%0d PAR_OUT=%0d K_PAR=%0d", TEST_NAME,
                 IN_CHANNELS, OUT_CHANNELS, KERNEL_SIZE, PAR_OUT, K_PAR);
        $display("==================================================");

        // Active mid-frame reset check. Drive enough input to force real math,
        // then reset and require the stream state to clear.
        for (int i = 0; i < ACTIVE_RESET_STEPS * IN_CHANNELS; i = i + 1) begin
            drive_beat(i, 1'b0);
        end
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
        @(posedge aclk);
        aresetn <= 1'b0;
        repeat (3) @(posedge aclk);
        if (m_axis_tvalid !== 1'b0) begin
            $display("[FAIL] %s m_axis_tvalid not cleared by active-frame reset", TEST_NAME);
            $finish;
        end
        aresetn <= 1'b1;
        repeat (2) @(posedge aclk);

        // Arm the scoreboard and the cycle counter on a negedge. frame_cycles
        // and frame_timer_active are also written by the always @(posedge aclk)
        // block below; toggling them ON a posedge makes the final increment
        // scheduler-dependent, and Icarus and XSim resolved it differently -
        // the reported frame length differed by exactly 1 cycle on conv4 and
        // conv5 while every data beat matched (Phase 1, CP-7).
        @(negedge aclk);
        out_beat_cnt       = 0;
        errors             = 0;
        frame_cycles       = 0;
        monitor_active     = 1'b1;
        frame_timer_active = 1'b1;

        for (int i = 0; i < TOTAL_IN_BEATS; i = i + 1) begin
            drive_beat(i, (i == TOTAL_IN_BEATS - 1));
        end
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;

        // The #1 matters. out_beat_cnt is updated with a blocking assignment
        // inside always @(posedge aclk); a bare @(posedge aclk) here races that
        // update, and Icarus and XSim resolve the race in opposite directions -
        // which showed up as a 1-cycle difference in the reported frame length
        // while every data beat matched (Phase 1, CP-7). Settling past the edge
        // makes the loop observe the same value in both simulators.
        while (out_beat_cnt < TOTAL_OUT_BEATS) begin
            @(posedge aclk);
            #1;
        end
        @(negedge aclk);
        frame_timer_active = 1'b0;
        repeat (5) @(posedge aclk);

        $display("[PERF] %s completed frame in %0d cycles with %0d%% output stall chance",
                 TEST_NAME, frame_cycles, stall_chance);
        if (errors == 0 && out_beat_cnt == TOTAL_OUT_BEATS) begin
            $display("[PASS] %s parallel RTL is bit-exact to golden output and AXI stall-safe [SUCCESS]", TEST_NAME);
        end else begin
            $display("[FAIL] %s errors=%0d beats=%0d/%0d", TEST_NAME, errors, out_beat_cnt, TOTAL_OUT_BEATS);
        end
        $display("==================================================");
        $finish;
    end

endmodule
