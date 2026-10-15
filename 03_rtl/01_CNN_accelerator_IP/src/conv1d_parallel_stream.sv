// Parallel-output Conv1d stream layer with optional kernel parallelism.
//
// The external AXI-Stream remains scalar. Internally PAR_OUT output channels
// are accumulated concurrently. K_PAR kernel taps can also be accumulated in
// parallel; K_PAR=1 is backward-compatible with the Phase-1 P32 engine.
//
// Weight layout expected by this module:
//   K_GROUPS    = KERNEL_SIZE / K_PAR
//   ISSUE_TERMS = IN_CHANNELS * K_GROUPS
//   packed_addr = out_group * ISSUE_TERMS
//               + input_channel * K_GROUPS
//               + kernel_group
//
//   flat_lane = output_lane * K_PAR + kernel_parallel_lane
//   weight_data_vec[flat_lane*WEIGHT_WIDTH +: WEIGHT_WIDTH]
//     = W[out_group*PAR_OUT + output_lane]
//        [input_channel]
//        [kernel_group*K_PAR + kernel_parallel_lane]
//
// The packed ROM changes only memory geometry. The number and values of model
// weights are unchanged.

`timescale 1ns / 1ps

module conv1d_parallel_stream #(
    parameter int DATA_WIDTH        = 16,
    parameter int WEIGHT_WIDTH      = 16,
    parameter int ACC_WIDTH         = 40,
    parameter int IN_CHANNELS       = 32,
    parameter int OUT_CHANNELS      = 256,
    parameter int KERNEL_SIZE       = 3,
    parameter int STRIDE            = 1,
    parameter int PAR_OUT           = 8,
    parameter int K_PAR             = 1,
    parameter bit REGISTERED_MATH   = 1,
    parameter int WEIGHT_ADDR_WIDTH = 12
)(
    input  logic                                      aclk,
    input  logic                                      aresetn,

    input  logic [DATA_WIDTH-1:0]                     s_axis_tdata,
    input  logic                                      s_axis_tvalid,
    output logic                                      s_axis_tready,
    input  logic                                      s_axis_tlast,

    output logic [DATA_WIDTH-1:0]                     m_axis_tdata,
    output logic                                      m_axis_tvalid,
    input  logic                                      m_axis_tready,
    output logic                                      m_axis_tlast,

    output logic [WEIGHT_ADDR_WIDTH-1:0]              weight_addr,
    input  logic [PAR_OUT*K_PAR*WEIGHT_WIDTH-1:0]    weight_data_vec,
    output logic [7:0]                                bias_addr,
    input  logic [WEIGHT_WIDTH-1:0]                  bias_data
);

    localparam int K_GROUPS    = KERNEL_SIZE / K_PAR;
    localparam int ISSUE_TERMS = IN_CHANNELS * K_GROUPS;
    localparam int OUT_GROUPS  = OUT_CHANNELS / PAR_OUT;
    localparam int IC_W        = (IN_CHANNELS <= 1) ? 1 : $clog2(IN_CHANNELS);
    localparam int KG_W        = (K_GROUPS <= 1) ? 1 : $clog2(K_GROUPS);
    localparam int GROUP_W     = (OUT_GROUPS <= 1) ? 1 : $clog2(OUT_GROUPS);
    localparam int LANE_W      = (PAR_OUT <= 1) ? 1 : $clog2(PAR_OUT);
    localparam int ISSUE_W     = (ISSUE_TERMS <= 1) ? 1 : $clog2(ISSUE_TERMS + 1);

`ifndef SYNTHESIS
    initial begin
        if ((OUT_CHANNELS % PAR_OUT) != 0) begin
            $fatal(1, "conv1d_parallel_stream requires OUT_CHANNELS divisible by PAR_OUT");
        end
        if ((KERNEL_SIZE % K_PAR) != 0) begin
            $fatal(1, "conv1d_parallel_stream requires KERNEL_SIZE divisible by K_PAR");
        end
        if (K_PAR < 1) begin
            $fatal(1, "conv1d_parallel_stream requires K_PAR >= 1");
        end
        if (STRIDE != 1) begin
            $fatal(1, "conv1d_parallel_stream currently supports STRIDE=1 only");
        end
        if ((OUT_GROUPS * ISSUE_TERMS) > (1 << WEIGHT_ADDR_WIDTH)) begin
            $fatal(1, "conv1d_parallel_stream WEIGHT_ADDR_WIDTH is too small");
        end
    end
`endif

    typedef enum logic [2:0] {
        STATE_IDLE       = 3'd0,
        STATE_READ       = 3'd1,
        STATE_CALC       = 3'd2,
        STATE_CALC_FLUSH = 3'd3,
        // STATE_WRITE is used only by the lightweight stub path. The registered
        // math path serialises its results from a snapshot buffer instead, so it
        // never blocks the MAC array on the output handshake (CP2-3).
        STATE_WRITE      = 3'd4,
        // Registered math only: the last group of a frame is still draining.
        STATE_DRAIN      = 3'd5
    } state_t;

    state_t state;

    generate
        if (REGISTERED_MATH) begin : gen_real_math
            logic [IC_W-1:0]       in_channel_cnt;
            logic [15:0]           in_step_cnt;
            logic [GROUP_W-1:0]    out_group_cnt;

            logic [ISSUE_W-1:0]    issue_cnt;
            logic [ISSUE_W-1:0]    mac_cnt;
            logic [IC_W-1:0]       issue_ic;
            logic [KG_W-1:0]       issue_kg;

            // shreg_extract="no" is a correctness constraint, not a resource hint.
            //
            // window_buf is written as a shift (KERNEL_SIZE-1 words move every input
            // beat) and read at an unrelated index, issue_kg. At the conv1 geometry --
            // IN_CHANNELS=1, so the array degenerates to KERNEL_SIZE words of one
            // DATA_WIDTH bus -- Vivado matched that shift pattern and inferred 16
            // SRL16E, one per data bit, with the read index driven onto the SRL
            // address. That is not the array the RTL describes, and the conv1 netlist
            // diverged from golden on 1678 of 2928 beats while the RTL was bit-exact.
            // The other five conv instances have IN_CHANNELS > 1, never matched the
            // pattern, and were unaffected -- which is why only conv1 broke.
            //
            // ram_style="registers" does NOT prevent this: it was measured to leave the
            // utilization and the 1678 mismatches bit-identical. SRL extraction is a
            // separate inference pass with its own attribute.
            (* shreg_extract = "no" *)
            logic signed [DATA_WIDTH-1:0] window_buf [IN_CHANNELS][KERNEL_SIZE];
            logic signed [DATA_WIDTH-1:0] activation_pipe [K_PAR];
            logic                           mac_valid_pipe;
            logic                           last_received_reg;

            // One accumulator per output lane and kernel-parallel lane. Using
            // independent accumulators keeps each DSP path to one MAC/cycle;
            // the K_PAR partial sums are reduced only after all terms finish.
            logic signed [ACC_WIDTH-1:0] acc [PAR_OUT][K_PAR];
            logic signed [ACC_WIDTH-1:0] acc_sum [PAR_OUT];
            logic signed [ACC_WIDTH-1:0] selected_acc_with_bias;
            logic signed [DATA_WIDTH-1:0] quantized_out;

            // CP2-3 output ping-pong.
            //
            // Previously the engine sat in STATE_WRITE serialising PAR_OUT
            // results while the MAC array idled, so every output group cost
            // ISSUE_TERMS + PAR_OUT cycles. The 2026-09-15 census showed conv6
            // saturated at 100 % of that cost and on the critical path, which
            // makes the PAR_OUT serialisation term worth removing: 9 728 cycles
            // for conv6, one per emitted beat.
            //
            // A finished group is snapshotted here and drained by an output
            // process that runs independently of the compute FSM. ONE buffer is
            // enough rather than a true ping-pong pair: draining takes PAR_OUT
            // beats against ISSUE_TERMS cycles to compute the next group, so the
            // buffer is always free in time unless the consumer backpressures —
            // and then stalling the MAC array is the correct response anyway.
            //
            // Buffering the accumulator sums rather than quantised values keeps
            // a single q_round_saturate instance. It also shortens the output
            // path: the K_PAR reduction now lands in the snapshot register
            // instead of sitting between the accumulators and the AXI data pins.
            logic signed [ACC_WIDTH-1:0] res_buf [PAR_OUT];
            logic [GROUP_W-1:0]          res_group;
            logic [LANE_W-1:0]           res_lane;
            logic                        res_valid;
            logic                        res_last;

            // CP2-5 output pipeline split.
            //
            // Post-route timing showed every one of the 20 worst setup paths
            // running from res_lane through the PAR_OUT:1 accumulator mux, the
            // bias add and the quantiser in ONE combinational chain — 17 logic
            // levels and 9.29 ns, which caps the design at about 106 MHz.
            //
            // This stage cuts that chain in half. Stage 1 selects a lane into
            // sel_acc (mux only); stage 2 does bias + quantise from a register.
            // Neither half carries the whole path, and the split costs one
            // ACC_WIDTH register per layer rather than any arithmetic change.
            //
            // It is a proper 1-deep pipeline with backpressure, not a bare
            // register: sel_valid/m_axis_tready form the second handshake, so
            // AXI4-Stream semantics hold and no beat is dropped or duplicated.
            logic signed [ACC_WIDTH-1:0] sel_acc;
            logic [GROUP_W-1:0]          sel_group;
            logic [LANE_W-1:0]           sel_lane;
            logic                        sel_valid;
            logic                        sel_last;

            logic                        s2_ready;
            logic                        s1_fire;

            // Incrementing group base removes out_group_cnt * ISSUE_TERMS from
            // the BRAM address critical path.
            logic [WEIGHT_ADDR_WIDTH-1:0] group_base_addr;
            logic [7:0]                   selected_out_channel;

            integer sum_lane;
            integer sum_kp;
            always_comb begin
                for (sum_lane = 0; sum_lane < PAR_OUT; sum_lane = sum_lane + 1) begin
                    acc_sum[sum_lane] = '0;
                    for (sum_kp = 0; sum_kp < K_PAR; sum_kp = sum_kp + 1) begin
                        acc_sum[sum_lane] = acc_sum[sum_lane] + acc[sum_lane][sum_kp];
                    end
                end
            end

            // Only issue a real address while the synchronous ROM request is
            // valid. During the delayed final MAC consume, hold the group base
            // instead of presenting a one-past-end address.
            assign weight_addr = ((state == STATE_CALC) && (issue_cnt < ISSUE_TERMS))
                               ? WEIGHT_ADDR_WIDTH'(group_base_addr + issue_cnt)
                               : group_base_addr;

            // Stage 2 drives the output: the bias add and quantiser now work
            // from a register instead of straight out of the accumulator mux.
            assign selected_out_channel = (sel_group * PAR_OUT) + sel_lane;
            assign bias_addr = selected_out_channel[7:0];

            assign s_axis_tready = (state == STATE_READ);
            assign m_axis_tvalid = sel_valid;
            assign m_axis_tdata  = quantized_out;
            assign m_axis_tlast  = sel_valid && sel_last;

            assign s2_ready = !sel_valid || m_axis_tready;
            assign s1_fire  = res_valid && s2_ready;

            // Preserve the verified Phase-1 numeric expression exactly. Only the
            // source of the accumulator changed: sel_acc holds the same value
            // acc_sum held when the group finished, one cycle later.
            always_comb begin
                selected_acc_with_bias = sel_acc +
                                         ($signed(bias_data) <<< 8);
            end

            q_round_saturate #(
                .N(ACC_WIDTH),
                .M(DATA_WIDTH),
                .SHIFT(14)
            ) i_round (
                .accumulator(selected_acc_with_bias),
                .saturated_out(quantized_out)
            );

            always_ff @(posedge aclk) begin : p_parallel_conv
                integer lane;
                integer kp;
                integer k;
                if (!aresetn) begin
                    state             <= STATE_IDLE;
                    in_channel_cnt    <= '0;
                    in_step_cnt       <= '0;
                    out_group_cnt     <= '0;
                    issue_cnt         <= '0;
                    mac_cnt           <= '0;
                    issue_ic          <= '0;
                    issue_kg          <= '0;
                    mac_valid_pipe    <= 1'b0;
                    last_received_reg <= 1'b0;
                    group_base_addr   <= '0;
                    res_valid         <= 1'b0;
                    res_lane          <= '0;
                    res_group         <= '0;
                    res_last          <= 1'b0;
                    sel_valid         <= 1'b0;
                    sel_lane          <= '0;
                    sel_group         <= '0;
                    sel_last          <= 1'b0;
                    sel_acc           <= '0;
                    for (kp = 0; kp < K_PAR; kp = kp + 1) begin
                        activation_pipe[kp] <= '0;
                    end
                    // res_buf is intentionally not reset: no lane is ever read
                    // until a completed group has been snapshotted into it.
                    for (lane = 0; lane < PAR_OUT; lane = lane + 1) begin
                        for (kp = 0; kp < K_PAR; kp = kp + 1) begin
                            acc[lane][kp] <= '0;
                        end
                    end
                    // window_buf is intentionally not reset. A tap is never
                    // consumed until K complete input steps have been written.
                end else begin
                    // Output serialiser. Deliberately outside the case: it runs
                    // in every state, which is exactly what lets the MAC array
                    // move on to the next group while this one leaves.
                    //
                    // Stage 2 latches one selected lane; stage 1 walks res_lane.
                    // The snapshot in STATE_CALC_FLUSH can never collide with
                    // this, because it only fires while res_valid is low.
                    if (s2_ready) begin
                        sel_valid <= res_valid;
                        if (res_valid) begin
                            sel_acc   <= res_buf[res_lane];
                            sel_group <= res_group;
                            sel_lane  <= res_lane;
                            sel_last  <= (res_group == OUT_GROUPS - 1) &&
                                         (res_lane == PAR_OUT - 1) &&
                                         res_last;
                        end
                    end

                    if (s1_fire) begin
                        if (res_lane == PAR_OUT - 1) begin
                            res_valid <= 1'b0;
                            res_lane  <= '0;
                        end else begin
                            res_lane <= res_lane + 1'b1;
                        end
                    end

                    case (state)
                        STATE_IDLE: begin
                            in_channel_cnt    <= '0;
                            in_step_cnt       <= '0;
                            out_group_cnt     <= '0;
                            issue_cnt         <= '0;
                            mac_cnt           <= '0;
                            issue_ic          <= '0;
                            issue_kg          <= '0;
                            mac_valid_pipe    <= 1'b0;
                            last_received_reg <= 1'b0;
                            group_base_addr   <= '0;
                            for (lane = 0; lane < PAR_OUT; lane = lane + 1) begin
                                for (kp = 0; kp < K_PAR; kp = kp + 1) begin
                                    acc[lane][kp] <= '0;
                                end
                            end
                            state <= STATE_READ;
                        end

                        STATE_READ: begin
                            if (s_axis_tvalid && s_axis_tready) begin
                                for (k = 0; k < KERNEL_SIZE - 1; k = k + 1) begin
                                    window_buf[in_channel_cnt][k] <= window_buf[in_channel_cnt][k+1];
                                end
                                window_buf[in_channel_cnt][KERNEL_SIZE-1] <= s_axis_tdata;

                                if (s_axis_tlast) begin
                                    last_received_reg <= 1'b1;
                                end

                                if (in_channel_cnt == IN_CHANNELS - 1) begin
                                    in_channel_cnt <= '0;
                                    in_step_cnt    <= in_step_cnt + 1'b1;

                                    if (in_step_cnt >= KERNEL_SIZE - 1) begin
                                        out_group_cnt   <= '0;
                                        issue_cnt       <= '0;
                                        mac_cnt         <= '0;
                                        issue_ic        <= '0;
                                        issue_kg        <= '0;
                                        mac_valid_pipe  <= 1'b0;
                                        group_base_addr <= '0;
                                        for (lane = 0; lane < PAR_OUT; lane = lane + 1) begin
                                            for (kp = 0; kp < K_PAR; kp = kp + 1) begin
                                                acc[lane][kp] <= '0;
                                            end
                                        end
                                        state <= STATE_CALC;
                                    end
                                end else begin
                                    in_channel_cnt <= in_channel_cnt + 1'b1;
                                end
                            end
                        end

                        STATE_CALC: begin
                            // Consume the synchronous ROM result and activation
                            // issued one cycle earlier. Each product has its own
                            // accumulator, so K_PAR scales DSP throughput without
                            // placing a K_PAR-wide adder tree in the MAC loop.
                            if (mac_valid_pipe) begin
                                for (lane = 0; lane < PAR_OUT; lane = lane + 1) begin
                                    for (kp = 0; kp < K_PAR; kp = kp + 1) begin
                                        acc[lane][kp] <= acc[lane][kp] +
                                            $signed(activation_pipe[kp]) *
                                            $signed(weight_data_vec[
                                                ((lane*K_PAR + kp)*WEIGHT_WIDTH) +: WEIGHT_WIDTH
                                            ]);
                                    end
                                end
                                mac_cnt <= mac_cnt + 1'b1;
                            end

                            // Issue one input-channel/kernel-group to all output
                            // lanes. For K_PAR=3 and K=3, this is one input
                            // channel per cycle and three taps per output lane.
                            if (issue_cnt < ISSUE_TERMS) begin
                                for (kp = 0; kp < K_PAR; kp = kp + 1) begin
                                    activation_pipe[kp] <=
                                        window_buf[issue_ic][issue_kg*K_PAR + kp];
                                end
                                mac_valid_pipe <= 1'b1;
                                issue_cnt      <= issue_cnt + 1'b1;

                                if (issue_kg == K_GROUPS - 1) begin
                                    issue_kg <= '0;
                                    if (issue_ic != IN_CHANNELS - 1) begin
                                        issue_ic <= issue_ic + 1'b1;
                                    end
                                end else begin
                                    issue_kg <= issue_kg + 1'b1;
                                end
                            end else begin
                                mac_valid_pipe <= 1'b0;
                            end

                            // Move to a one-cycle flush after consuming the last
                            // delayed ROM word so the final nonblocking MAC update
                            // is visible to acc_sum before STATE_WRITE.
                            if (mac_valid_pipe && (mac_cnt == ISSUE_TERMS - 1)) begin
                                state <= STATE_CALC_FLUSH;
                            end
                        end

                        STATE_CALC_FLUSH: begin
                            mac_valid_pipe <= 1'b0;

                            // Hand the finished group to the output buffer and
                            // start the next one in the same cycle. The wait on
                            // res_valid is the only thing that can stall the MAC
                            // array, and it needs PAR_OUT beats to drain against
                            // ISSUE_TERMS cycles to compute — so it only bites
                            // when the consumer is backpressuring, which is the
                            // one case where stalling is correct.
                            if (!res_valid) begin
                                for (lane = 0; lane < PAR_OUT; lane = lane + 1) begin
                                    res_buf[lane] <= acc_sum[lane];
                                end
                                res_group <= out_group_cnt;
                                res_lane  <= '0;
                                res_last  <= last_received_reg;
                                res_valid <= 1'b1;

                                // The accumulators belong to the next group from
                                // here on; the snapshot above is what the output
                                // side will serialise.
                                for (lane = 0; lane < PAR_OUT; lane = lane + 1) begin
                                    for (kp = 0; kp < K_PAR; kp = kp + 1) begin
                                        acc[lane][kp] <= '0;
                                    end
                                end
                                issue_cnt <= '0;
                                mac_cnt   <= '0;
                                issue_ic  <= '0;
                                issue_kg  <= '0;

                                if (out_group_cnt == OUT_GROUPS - 1) begin
                                    out_group_cnt   <= '0;
                                    group_base_addr <= '0;
                                    if (last_received_reg) begin
                                        // Hold until the frame's final beat and
                                        // its TLAST have actually left, so the
                                        // engine cannot report idle early.
                                        state <= STATE_DRAIN;
                                    end else begin
                                        // Reading the next input step does not
                                        // touch res_buf, so it overlaps the
                                        // drain rather than waiting for it.
                                        state <= STATE_READ;
                                    end
                                end else begin
                                    out_group_cnt   <= out_group_cnt + 1'b1;
                                    group_base_addr <= group_base_addr + ISSUE_TERMS;
                                    state           <= STATE_CALC;
                                end
                            end
                        end

                        STATE_DRAIN: begin
                            // Both pipeline stages must be empty: the frame's
                            // final beat and its TLAST have to be on the wire
                            // before the engine can report idle.
                            if (!res_valid && !sel_valid) begin
                                last_received_reg <= 1'b0;
                                state             <= STATE_IDLE;
                            end
                        end

                        default: state <= STATE_IDLE;
                    endcase
                end
            end

        end else begin : gen_stub_bypass
            // Lightweight shape-preserving mode retained for smoke tests.
            logic [15:0] in_step_cnt;
            logic [IC_W-1:0] in_channel_cnt;
            logic [15:0] out_channel_cnt;
            logic signed [DATA_WIDTH-1:0] last_input_val [IN_CHANNELS];
            logic last_received_reg;

            assign s_axis_tready = (state == STATE_READ);
            assign m_axis_tvalid = (state == STATE_WRITE);
            assign weight_addr   = WEIGHT_ADDR_WIDTH'(out_channel_cnt / PAR_OUT);
            assign bias_addr     = out_channel_cnt[7:0];
            assign m_axis_tdata  = (out_channel_cnt < IN_CHANNELS)
                                 ? last_input_val[out_channel_cnt] + bias_data[DATA_WIDTH-1:0]
                                 : DATA_WIDTH'(out_channel_cnt) + weight_data_vec[WEIGHT_WIDTH-1:0];
            assign m_axis_tlast  = (state == STATE_WRITE) &&
                                   (out_channel_cnt == OUT_CHANNELS - 1) &&
                                   last_received_reg;

            always_ff @(posedge aclk) begin
                integer i;
                if (!aresetn) begin
                    state             <= STATE_IDLE;
                    in_step_cnt       <= '0;
                    in_channel_cnt    <= '0;
                    out_channel_cnt   <= '0;
                    last_received_reg <= 1'b0;
                    for (i = 0; i < IN_CHANNELS; i = i + 1) begin
                        last_input_val[i] <= '0;
                    end
                end else begin
                    case (state)
                        STATE_IDLE: begin
                            in_step_cnt       <= '0;
                            in_channel_cnt    <= '0;
                            out_channel_cnt   <= '0;
                            last_received_reg <= 1'b0;
                            state <= STATE_READ;
                        end

                        STATE_READ: begin
                            if (s_axis_tvalid && s_axis_tready) begin
                                last_input_val[in_channel_cnt] <= s_axis_tdata;
                                if (s_axis_tlast) begin
                                    last_received_reg <= 1'b1;
                                end
                                if (in_channel_cnt == IN_CHANNELS - 1) begin
                                    in_channel_cnt <= '0;
                                    in_step_cnt <= in_step_cnt + 1'b1;
                                    if (in_step_cnt >= KERNEL_SIZE - 1) begin
                                        out_channel_cnt <= '0;
                                        state <= STATE_WRITE;
                                    end
                                end else begin
                                    in_channel_cnt <= in_channel_cnt + 1'b1;
                                end
                            end
                        end

                        STATE_WRITE: begin
                            if (m_axis_tvalid && m_axis_tready) begin
                                if (out_channel_cnt == OUT_CHANNELS - 1) begin
                                    out_channel_cnt <= '0;
                                    if (last_received_reg) begin
                                        last_received_reg <= 1'b0;
                                        state <= STATE_IDLE;
                                    end else begin
                                        state <= STATE_READ;
                                    end
                                end else begin
                                    out_channel_cnt <= out_channel_cnt + 1'b1;
                                end
                            end
                        end

                        default: state <= STATE_IDLE;
                    endcase
                end
            end
        end
    endgenerate

endmodule
