

`timescale 1ns / 1ps

module linear_layer_stream #(
    parameter int DATA_WIDTH   = 16,
    parameter int WEIGHT_WIDTH = 16,
    parameter int IN_FEATURES  = 256,
    parameter int OUT_FEATURES = 64
)(
    input  logic                     aclk,
    input  logic                     aresetn,

    // AXI-Stream Slave (Input)
    input  logic [DATA_WIDTH-1:0]    s_axis_tdata,
    input  logic                     s_axis_tvalid,
    output logic                     s_axis_tready,
    input  logic                     s_axis_tlast,

    // AXI-Stream Master (Output)
    output logic [DATA_WIDTH-1:0]    m_axis_tdata,
    output logic                     m_axis_tvalid,
    input  logic                     m_axis_tready,
    output logic                     m_axis_tlast,

    // BRAM weights & bias interfaces
    output logic [13:0]              weight_addr,
    input  logic [WEIGHT_WIDTH-1:0]  weight_data,
    output logic [7:0]               bias_addr,
    input  logic [WEIGHT_WIDTH-1:0]  bias_data
);

    // FSM States
    typedef enum logic [1:0] {
        STATE_IDLE  = 2'b00,
        STATE_READ  = 2'b01,
        STATE_CALC  = 2'b10,
        STATE_WRITE = 2'b11
    } state_t;

    state_t state;

    // Counters
    logic [$clog2(IN_FEATURES):0]    in_cnt;    // input buffer write counter
    logic [$clog2(OUT_FEATURES):0]   out_cnt;   // output channel/feature loop counter
    logic [$clog2(IN_FEATURES+2):0]  calc_cnt;  // calculation loop counter: goes 0 to IN_FEATURES+1

    // Memory buffer to hold input vector
    logic signed [DATA_WIDTH-1:0] in_buf [IN_FEATURES];

    // Math Registers
    logic signed [39:0] acc;                  // 40-bit accumulator
    logic signed [DATA_WIDTH-1:0] in_val;     // Registered delayed input value
    logic signed [WEIGHT_WIDTH-1:0] bias_reg; // Registered bias value

    // Output holding register
    logic signed [DATA_WIDTH-1:0] out_buf;

    // Rounding and Saturation instance
    logic signed [39:0] acc_with_bias;
    logic signed [DATA_WIDTH-1:0] out_buf_in;

    // Q18.22 -> Q8.8 rounding & saturation (shift = 14)
    q_round_saturate #(
        .N(40),
        .M(DATA_WIDTH),
        .SHIFT(14)
    ) i_round (
        .accumulator(acc_with_bias),
        .saturated_out(out_buf_in)
    );

    // BRAM Address generation:
    // Address = out_cnt * IN_FEATURES + calc_cnt
    // During calculation, we request index `calc_cnt` when `calc_cnt < IN_FEATURES`.
    always_comb begin
        if (state == STATE_CALC && calc_cnt < IN_FEATURES) begin
            weight_addr = 14'(out_cnt * IN_FEATURES + calc_cnt);
        end else begin
            weight_addr = '0;
        end
        bias_addr = 8'(out_cnt); // Bias is constant for the current output channel
    end

    // Combinational AXI interfaces
    assign s_axis_tready = (state == STATE_READ);
    assign m_axis_tvalid = (state == STATE_WRITE);
    assign m_axis_tdata  = out_buf;
    assign m_axis_tlast  = (state == STATE_WRITE) && (out_cnt == OUT_FEATURES - 1);

    // Sum accumulator with bias: bias is Q2.14, we shift left by 8 to align with Q18.22 accumulator
    assign acc_with_bias = acc + ($signed(bias_reg) << 8);

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            state    <= STATE_IDLE;
            in_cnt   <= '0;
            out_cnt  <= '0;
            calc_cnt <= '0;
            acc      <= '0;
            in_val   <= '0;
            bias_reg <= '0;
            out_buf  <= '0;
            for (int i = 0; i < IN_FEATURES; i = i + 1) begin
                in_buf[i] = '0;
            end
        end else begin
            case (state)
                STATE_IDLE: begin
                    in_cnt   <= '0;
                    out_cnt  <= '0;
                    calc_cnt <= '0;
                    acc      <= '0;
                    state    <= STATE_READ;
                end

                STATE_READ: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        in_buf[in_cnt] <= s_axis_tdata;
                        if (s_axis_tlast || (in_cnt == IN_FEATURES - 1)) begin
                            in_cnt   <= '0;
                            out_cnt  <= '0;
                            calc_cnt <= '0;
                            acc      <= '0;
                            state    <= STATE_CALC;
                        end else begin
                            in_cnt   <= in_cnt + 1;
                        end
                    end
                end

                STATE_CALC: begin
                    // Register the bias_data on cycle 1, after the 1-cycle ROM latency
                    if (calc_cnt == 1) begin
                        bias_reg <= bias_data;
                    end

                    // Pipeline implementation:
                    // Cycle 0 (calc_cnt = 0):
                    //   We drive weight_addr = out_cnt * IN_FEATURES + 0.
                    //   We register in_val <= in_buf[0].
                    //   We do NOT accumulate yet.
                    // Cycle 1..IN_FEATURES-1:
                    //   RAM returns weight_data for (calc_cnt - 1).
                    //   We accumulate: acc <= acc + in_val * weight_data.
                    //   We drive weight_addr = out_cnt * IN_FEATURES + calc_cnt.
                    //   We register in_val <= in_buf[calc_cnt].
                    // Cycle IN_FEATURES (calc_cnt = IN_FEATURES):
                    //   RAM returns weight_data for IN_FEATURES-1.
                    //   We accumulate: acc <= acc + in_val * weight_data.
                    // Cycle IN_FEATURES+1 (calc_cnt = IN_FEATURES+1):
                    //   The final value of acc is fully calculated and stable.
                    //   On the clock edge at the end of this cycle:
                    //     We register out_buf <= out_buf_in.
                    //     We transition to STATE_WRITE.

                    if (calc_cnt < IN_FEATURES) begin
                        in_val   <= in_buf[calc_cnt];
                        calc_cnt <= calc_cnt + 1;
                    end else if (calc_cnt == IN_FEATURES) begin
                        calc_cnt <= calc_cnt + 1;
                    end

                    if (calc_cnt > 0 && calc_cnt <= IN_FEATURES) begin
                        acc <= acc + $signed(in_val) * $signed(weight_data);
                    end

                    if (calc_cnt == IN_FEATURES + 1) begin
                        out_buf  <= out_buf_in;
                        state    <= STATE_WRITE;
                    end
                end

                STATE_WRITE: begin
                    if (m_axis_tvalid && m_axis_tready) begin
                        if (out_cnt == OUT_FEATURES - 1) begin
                            out_cnt <= '0;
                            state   <= STATE_READ;
                        end else begin
                            out_cnt  <= out_cnt + 1;
                            calc_cnt <= '0;
                            acc      <= '0;
                            state    <= STATE_CALC;
                        end
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
