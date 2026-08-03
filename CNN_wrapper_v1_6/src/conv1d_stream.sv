`timescale 1ns / 1ps

module conv1d_stream #(
    parameter int DATA_WIDTH        = 16,
    parameter int WEIGHT_WIDTH      = 16,
    parameter int IN_CHANNELS       = 16,
    parameter int OUT_CHANNELS      = 16,
    parameter int KERNEL_SIZE       = 5,
    parameter int STRIDE            = 1,
    parameter bit REGISTERED_MATH   = 1,
    parameter int WEIGHT_ADDR_WIDTH = 12
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
    output logic [WEIGHT_ADDR_WIDTH-1:0] weight_addr,
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

    generate
        if (REGISTERED_MATH) begin : gen_real_math
            localparam int LIMIT = IN_CHANNELS * KERNEL_SIZE;

            // Counters
            logic [$clog2(IN_CHANNELS):0]         in_channel_cnt;
            logic [15:0]                          in_step_cnt;
            logic [$clog2(OUT_CHANNELS):0]        out_channel_cnt;
            logic [$clog2(LIMIT+2):0]             calc_cnt;
            logic [$clog2(IN_CHANNELS):0]         ic_cnt;
            logic [$clog2(KERNEL_SIZE):0]         k_cnt;

            // Local shift register buffer to hold sliding window activations
            logic signed [DATA_WIDTH-1:0] window_buf [IN_CHANNELS][KERNEL_SIZE];

            // Status registers
            logic last_received_reg;

            // Math Registers
            logic signed [39:0] acc;                  // 40-bit accumulator
            logic signed [DATA_WIDTH-1:0] in_val;     // Registered delayed input value
            logic signed [WEIGHT_WIDTH-1:0] bias_reg; // Registered bias value
            logic signed [DATA_WIDTH-1:0] out_buf;    // Output holding register

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

            // BRAM Address generation
            always_comb begin
                if (state == STATE_CALC && calc_cnt < LIMIT) begin
                    weight_addr = WEIGHT_ADDR_WIDTH'(out_channel_cnt * LIMIT + ic_cnt * KERNEL_SIZE + k_cnt);
                end else begin
                    weight_addr = '0;
                end
                bias_addr = 8'(out_channel_cnt); // Bias is constant for the current output channel
            end

            // Combinational AXI interfaces
            assign s_axis_tready = (state == STATE_READ);
            assign m_axis_tvalid = (state == STATE_WRITE);
            assign m_axis_tdata  = out_buf;
            assign m_axis_tlast  = (state == STATE_WRITE) && 
                                  (out_channel_cnt == OUT_CHANNELS - 1) && 
                                  last_received_reg;

            // Sum accumulator with bias: bias is Q2.14, we shift left by 8 to align with Q18.22 accumulator
            assign acc_with_bias = acc + ($signed(bias_reg) << 8);

            always_ff @(posedge aclk) begin
                if (!aresetn) begin
                    state             <= STATE_IDLE;
                    in_channel_cnt    <= '0;
                    in_step_cnt       <= '0;
                    out_channel_cnt   <= '0;
                    calc_cnt          <= '0;
                    ic_cnt            <= '0;
                    k_cnt             <= '0;
                    last_received_reg <= 1'b0;
                    acc               <= '0;
                    in_val            <= '0;
                    bias_reg          <= '0;
                    out_buf           <= '0;
                    for (int c = 0; c < IN_CHANNELS; c = c + 1) begin
                        for (int k = 0; k < KERNEL_SIZE; k = k + 1) begin
                            window_buf[c][k] = '0;
                        end
                    end
                end else begin
                    case (state)
                        STATE_IDLE: begin
                            in_channel_cnt    <= '0;
                            in_step_cnt       <= '0;
                            out_channel_cnt   <= '0;
                            calc_cnt          <= '0;
                            ic_cnt            <= '0;
                            k_cnt             <= '0;
                            last_received_reg <= 1'b0;
                            acc               <= '0;
                            state             <= STATE_READ;
                        end

                        STATE_READ: begin
                            if (s_axis_tvalid && s_axis_tready) begin
                                // Shift input sample into window buffer
                                for (int k = 0; k < KERNEL_SIZE - 1; k = k + 1) begin
                                    window_buf[in_channel_cnt][k] <= window_buf[in_channel_cnt][k+1];
                                end
                                window_buf[in_channel_cnt][KERNEL_SIZE-1] <= s_axis_tdata;

                                // Track frame termination
                                if (s_axis_tlast) begin
                                    last_received_reg <= 1'b1;
                                end

                                // Increment channels
                                if (in_channel_cnt == IN_CHANNELS - 1) begin
                                    in_channel_cnt <= '0;
                                    in_step_cnt    <= in_step_cnt + 1;

                                    // Once K temporal steps are read, we can produce the output step
                                    if (in_step_cnt >= KERNEL_SIZE - 1) begin
                                        calc_cnt        <= '0;
                                        ic_cnt          <= '0;
                                        k_cnt           <= '0;
                                        out_channel_cnt <= '0;
                                        acc             <= '0;
                                        state           <= STATE_CALC;
                                    end
                                end else begin
                                    in_channel_cnt <= in_channel_cnt + 1;
                                end
                            end
                        end

                        STATE_CALC: begin
                            // Register the bias_data on cycle 1, after the 1-cycle ROM latency
                            if (calc_cnt == 1) begin
                                bias_reg <= bias_data;
                            end

                            if (calc_cnt < LIMIT) begin
                                in_val   <= window_buf[ic_cnt][k_cnt];
                                calc_cnt <= calc_cnt + 1;
                                
                                if (k_cnt == KERNEL_SIZE - 1) begin
                                    k_cnt  <= '0;
                                    ic_cnt <= ic_cnt + 1;
                                end else begin
                                    k_cnt  <= k_cnt + 1;
                                end
                            end else if (calc_cnt == LIMIT) begin
                                calc_cnt <= calc_cnt + 1;
                            end

                            if (calc_cnt > 0 && calc_cnt <= LIMIT) begin
                                acc <= acc + $signed(in_val) * $signed(weight_data);
                            end

                            if (calc_cnt == LIMIT + 1) begin
                                out_buf <= out_buf_in;
                                state   <= STATE_WRITE;
                            end
                        end

                        STATE_WRITE: begin
                            if (m_axis_tvalid && m_axis_tready) begin
                                if (out_channel_cnt == OUT_CHANNELS - 1) begin
                                    out_channel_cnt <= '0;
                                    if (last_received_reg) begin
                                        state             <= STATE_IDLE;
                                        last_received_reg <= 1'b0;
                                    end else begin
                                        state <= STATE_READ;
                                    end
                                end else begin
                                    out_channel_cnt <= out_channel_cnt + 1;
                                    calc_cnt        <= '0;
                                    ic_cnt          <= '0;
                                    k_cnt           <= '0;
                                    acc             <= '0;
                                    state           <= STATE_CALC;
                                end
                            end
                        end

                        default: state <= STATE_IDLE;
                    endcase
                end
            end

        end else begin : gen_stub_bypass
            // Counters
            logic [$clog2(IN_CHANNELS):0]  in_channel_cnt;
            logic [15:0]                   in_step_cnt;
            logic [$clog2(OUT_CHANNELS):0] out_channel_cnt;
            logic signed [DATA_WIDTH-1:0]  last_input_val [IN_CHANNELS];
            logic                          last_received_reg;

            assign s_axis_tready = (state == STATE_READ);
            assign m_axis_tvalid = (state == STATE_WRITE);
            assign weight_addr = WEIGHT_ADDR_WIDTH'(out_channel_cnt);
            assign bias_addr   = 8'(out_channel_cnt);

            always_comb begin
                if (out_channel_cnt < IN_CHANNELS) begin
                    m_axis_tdata = last_input_val[out_channel_cnt] + bias_data[DATA_WIDTH-1:0];
                end else begin
                    m_axis_tdata = DATA_WIDTH'(out_channel_cnt) + weight_data[DATA_WIDTH-1:0];
                end
            end

            assign m_axis_tlast = (state == STATE_WRITE) &&
                                  (out_channel_cnt == OUT_CHANNELS - 1) &&
                                  last_received_reg;

            always_ff @(posedge aclk) begin
                if (!aresetn) begin
                    state             <= STATE_IDLE;
                    in_channel_cnt    <= '0;
                    in_step_cnt       <= '0;
                    out_channel_cnt   <= '0;
                    last_received_reg <= 1'b0;
                    for (int i = 0; i < IN_CHANNELS; i = i + 1) begin
                        last_input_val[i] = '0;
                    end
                end else begin
                    case (state)
                        STATE_IDLE: begin
                            in_channel_cnt    <= '0;
                            in_step_cnt       <= '0;
                            out_channel_cnt   <= '0;
                            last_received_reg <= 1'b0;
                            state             <= STATE_READ;
                        end

                        STATE_READ: begin
                            if (s_axis_tvalid && s_axis_tready) begin
                                last_input_val[in_channel_cnt] <= s_axis_tdata;

                                if (s_axis_tlast) begin
                                    last_received_reg <= 1'b1;
                                end

                                if (in_channel_cnt == IN_CHANNELS - 1) begin
                                    in_channel_cnt <= '0;
                                    in_step_cnt    <= in_step_cnt + 1;

                                    if (in_step_cnt >= KERNEL_SIZE - 1) begin
                                        state <= STATE_WRITE;
                                    end
                                end else begin
                                    in_channel_cnt <= in_channel_cnt + 1;
                                end
                            end
                        end

                        STATE_WRITE: begin
                            if (m_axis_tvalid && m_axis_tready) begin
                                if (out_channel_cnt == OUT_CHANNELS - 1) begin
                                    out_channel_cnt <= '0;
                                    if (last_received_reg) begin
                                        state             <= STATE_IDLE;
                                        last_received_reg <= 1'b0;
                                    end else begin
                                        state <= STATE_READ;
                                    end
                                end else begin
                                    out_channel_cnt <= out_channel_cnt + 1;
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
