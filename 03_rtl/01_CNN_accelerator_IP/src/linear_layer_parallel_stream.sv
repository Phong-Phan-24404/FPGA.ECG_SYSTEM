// Parallel-output fully connected layer.
// Computes PAR_OUT output features concurrently while preserving the scalar
// AXI-Stream interface and the Phase-1 fixed-point arithmetic contract.
//
// Weight layout:
//   packed_addr = out_group * IN_FEATURES + input_feature
//   weight_data_vec[lane*WEIGHT_WIDTH +: WEIGHT_WIDTH]
//     = W[out_group*PAR_OUT + lane][input_feature]

`timescale 1ns / 1ps

module linear_layer_parallel_stream #(
    parameter int DATA_WIDTH        = 16,
    parameter int WEIGHT_WIDTH      = 16,
    parameter int ACC_WIDTH         = 40,
    parameter int IN_FEATURES       = 256,
    parameter int OUT_FEATURES      = 64,
    parameter int PAR_OUT           = 16,
    parameter int WEIGHT_ADDR_WIDTH = 10
)(
    input  logic                                     aclk,
    input  logic                                     aresetn,

    input  logic [DATA_WIDTH-1:0]                    s_axis_tdata,
    input  logic                                     s_axis_tvalid,
    output logic                                     s_axis_tready,
    input  logic                                     s_axis_tlast,

    output logic [DATA_WIDTH-1:0]                    m_axis_tdata,
    output logic                                     m_axis_tvalid,
    input  logic                                     m_axis_tready,
    output logic                                     m_axis_tlast,

    output logic [WEIGHT_ADDR_WIDTH-1:0]             weight_addr,
    input  logic [PAR_OUT*WEIGHT_WIDTH-1:0]         weight_data_vec,
    output logic [7:0]                               bias_addr,
    input  logic [WEIGHT_WIDTH-1:0]                 bias_data
);

    localparam int OUT_GROUPS = OUT_FEATURES / PAR_OUT;
    localparam int IN_W       = (IN_FEATURES <= 1) ? 1 : $clog2(IN_FEATURES + 1);
    localparam int GROUP_W    = (OUT_GROUPS <= 1) ? 1 : $clog2(OUT_GROUPS);
    localparam int LANE_W     = (PAR_OUT <= 1) ? 1 : $clog2(PAR_OUT);

`ifndef SYNTHESIS
    initial begin
        if ((OUT_FEATURES % PAR_OUT) != 0) begin
            $fatal(1, "linear_layer_parallel_stream requires OUT_FEATURES divisible by PAR_OUT");
        end
        if ((OUT_GROUPS * IN_FEATURES) > (1 << WEIGHT_ADDR_WIDTH)) begin
            $fatal(1, "linear_layer_parallel_stream WEIGHT_ADDR_WIDTH is too small");
        end
    end
`endif

    typedef enum logic [2:0] {
        STATE_IDLE       = 3'd0,
        STATE_READ       = 3'd1,
        STATE_CALC       = 3'd2,
        STATE_CALC_FLUSH = 3'd3,
        STATE_WRITE      = 3'd4
    } state_t;

    state_t state;

    logic signed [DATA_WIDTH-1:0] in_buf [IN_FEATURES];
    logic [IN_W-1:0]              in_cnt;
    logic [GROUP_W-1:0]           out_group_cnt;
    logic [LANE_W-1:0]            write_lane_cnt;

    logic [IN_W-1:0]              issue_cnt;
    logic [IN_W-1:0]              mac_cnt;
    logic signed [DATA_WIDTH-1:0] in_val_pipe;
    logic                          mac_valid_pipe;

    logic signed [ACC_WIDTH-1:0] acc [PAR_OUT];
    logic signed [ACC_WIDTH-1:0] selected_acc_with_bias;
    logic signed [DATA_WIDTH-1:0] quantized_out;

    logic [WEIGHT_ADDR_WIDTH-1:0] group_base_addr;
    logic [7:0]                   selected_out_feature;

    assign weight_addr = ((state == STATE_CALC) && (issue_cnt < IN_FEATURES))
                       ? WEIGHT_ADDR_WIDTH'(group_base_addr + issue_cnt)
                       : group_base_addr;

    assign selected_out_feature = (out_group_cnt * PAR_OUT) + write_lane_cnt;
    assign bias_addr = selected_out_feature[7:0];

    assign s_axis_tready = (state == STATE_READ);
    assign m_axis_tvalid = (state == STATE_WRITE);
    assign m_axis_tdata  = quantized_out;
    assign m_axis_tlast  = (state == STATE_WRITE) &&
                           (out_group_cnt == OUT_GROUPS - 1) &&
                           (write_lane_cnt == PAR_OUT - 1);

    // Preserve the verified Phase-1 arithmetic expression.
    always_comb begin
        selected_acc_with_bias = acc[write_lane_cnt] +
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

    always_ff @(posedge aclk) begin : p_parallel_linear
        integer lane;
        if (!aresetn) begin
            state           <= STATE_IDLE;
            in_cnt          <= '0;
            out_group_cnt   <= '0;
            write_lane_cnt  <= '0;
            issue_cnt       <= '0;
            mac_cnt         <= '0;
            in_val_pipe     <= '0;
            mac_valid_pipe  <= 1'b0;
            group_base_addr <= '0;
            for (lane = 0; lane < PAR_OUT; lane = lane + 1) begin
                acc[lane] <= '0;
            end
            // in_buf is intentionally not reset. The full vector is written
            // before STATE_CALC can consume it.
        end else begin
            case (state)
                STATE_IDLE: begin
                    in_cnt          <= '0;
                    out_group_cnt   <= '0;
                    write_lane_cnt  <= '0;
                    issue_cnt       <= '0;
                    mac_cnt         <= '0;
                    mac_valid_pipe  <= 1'b0;
                    group_base_addr <= '0;
                    for (lane = 0; lane < PAR_OUT; lane = lane + 1) begin
                        acc[lane] <= '0;
                    end
                    state <= STATE_READ;
                end

                STATE_READ: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        in_buf[in_cnt] <= s_axis_tdata;
                        if (s_axis_tlast || (in_cnt == IN_FEATURES - 1)) begin
                            in_cnt          <= '0;
                            out_group_cnt   <= '0;
                            write_lane_cnt  <= '0;
                            issue_cnt       <= '0;
                            mac_cnt         <= '0;
                            mac_valid_pipe  <= 1'b0;
                            group_base_addr <= '0;
                            for (lane = 0; lane < PAR_OUT; lane = lane + 1) begin
                                acc[lane] <= '0;
                            end
                            state <= STATE_CALC;
                        end else begin
                            in_cnt <= in_cnt + 1'b1;
                        end
                    end
                end

                STATE_CALC: begin
                    if (mac_valid_pipe) begin
                        for (lane = 0; lane < PAR_OUT; lane = lane + 1) begin
                            acc[lane] <= acc[lane] +
                                $signed(in_val_pipe) *
                                $signed(weight_data_vec[lane*WEIGHT_WIDTH +: WEIGHT_WIDTH]);
                        end
                        mac_cnt <= mac_cnt + 1'b1;
                    end

                    if (issue_cnt < IN_FEATURES) begin
                        in_val_pipe    <= in_buf[issue_cnt];
                        issue_cnt      <= issue_cnt + 1'b1;
                        mac_valid_pipe <= 1'b1;
                    end else begin
                        mac_valid_pipe <= 1'b0;
                    end

                    if (mac_valid_pipe && (mac_cnt == IN_FEATURES - 1)) begin
                        state <= STATE_CALC_FLUSH;
                    end
                end

                STATE_CALC_FLUSH: begin
                    mac_valid_pipe <= 1'b0;
                    write_lane_cnt <= '0;
                    state          <= STATE_WRITE;
                end

                STATE_WRITE: begin
                    if (m_axis_tvalid && m_axis_tready) begin
                        if (write_lane_cnt == PAR_OUT - 1) begin
                            write_lane_cnt <= '0;
                            if (out_group_cnt == OUT_GROUPS - 1) begin
                                out_group_cnt   <= '0;
                                group_base_addr <= '0;
                                state <= STATE_IDLE;
                            end else begin
                                out_group_cnt   <= out_group_cnt + 1'b1;
                                group_base_addr <= group_base_addr + IN_FEATURES;
                                issue_cnt       <= '0;
                                mac_cnt         <= '0;
                                mac_valid_pipe  <= 1'b0;
                                for (lane = 0; lane < PAR_OUT; lane = lane + 1) begin
                                    acc[lane] <= '0;
                                end
                                state <= STATE_CALC;
                            end
                        end else begin
                            write_lane_cnt <= write_lane_cnt + 1'b1;
                        end
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
