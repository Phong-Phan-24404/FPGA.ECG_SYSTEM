// Fused ReLU + global 1D max pool — Phase 2, CP2-4.
//
// Replaces a `relu_stream` followed by a `global_maxpool1d_stream` with a single
// stage. Reduces the temporal dimension (STEPS) to 1 by tracking a running
// maximum per channel, with ReLU applied to each incoming value first.
//
// ORDERING. The contract is quantize -> ReLU -> max, and it is preserved: the
// quantisation happens upstream in the convolution engine, ReLU is applied here
// to each arriving beat, and only the ReLU'd value ever reaches the comparator.
// Because ReLU makes every value non-negative, seeding the running maximum from
// the first step (rather than from a large negative constant) stays correct, and
// that is exactly what the unfused pair did.
//
// SCOPE OF THIS CHANGE, and why it is not the fusion CP2-4 originally described.
//
// CP2-4 was written to move the tail inside the convolution engine so that only
// CHANNELS pooled values would cross to fc1 instead of CHANNELS*STEPS
// intermediates. The 2026-09-15 handshake census made that pointless: conv6 is
// blocked 0.0 % of the frame, so those intermediate beats cost it nothing, and
// the pooled values still have to be serialised either way. Measured benefit of
// full fusion is a couple of handshake cycles.
//
// Against that, full fusion would have deleted the conv6 and relu6 golden taps —
// 9 728 checked values each — and put a comparator on what post-route timing
// shows is the design's critical path (conv6's output quantiser). Merging the
// two tail stages instead keeps conv6's tap intact, keeps the pooled-output
// golden tap intact, removes a pipeline stage and a module, and leaves the
// critical path untouched.

`timescale 1ns / 1ps

module relu_global_maxpool1d_stream #(
    parameter int DATA_WIDTH = 16,
    parameter int CHANNELS   = 256,
    parameter int STEPS      = 38
)(
    input  logic                  aclk,
    input  logic                  aresetn,

    input  logic [DATA_WIDTH-1:0] s_axis_tdata,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,
    input  logic                  s_axis_tlast,

    output logic [DATA_WIDTH-1:0] m_axis_tdata,
    output logic                  m_axis_tvalid,
    input  logic                  m_axis_tready,
    output logic                  m_axis_tlast
);

    typedef enum logic [1:0] {
        STATE_IDLE  = 2'b00,
        STATE_READ  = 2'b01,
        STATE_WRITE = 2'b10
    } state_t;

    state_t state;

    logic [$clog2(CHANNELS):0] in_c_cnt;
    logic [15:0]               step_cnt;
    logic [$clog2(CHANNELS):0] out_c_cnt;

    logic signed [DATA_WIDTH-1:0] max_mem [CHANNELS];

    // ReLU, identical to relu_stream's expression: a negative value becomes
    // zero, everything else passes through untouched.
    logic signed [DATA_WIDTH-1:0] relu_data;
    assign relu_data = (s_axis_tdata[DATA_WIDTH-1] == 1'b1)
                     ? '0
                     : $signed(s_axis_tdata);

    assign s_axis_tready = (state == STATE_READ);
    assign m_axis_tvalid = (state == STATE_WRITE);
    assign m_axis_tdata  = max_mem[out_c_cnt];
    assign m_axis_tlast  = (state == STATE_WRITE) && (out_c_cnt == CHANNELS - 1);

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            state     <= STATE_IDLE;
            in_c_cnt  <= '0;
            step_cnt  <= '0;
            out_c_cnt <= '0;
            for (int i = 0; i < CHANNELS; i = i + 1) begin
                max_mem[i] <= '0;
            end
        end else begin
            case (state)
                STATE_IDLE: begin
                    in_c_cnt  <= '0;
                    step_cnt  <= '0;
                    out_c_cnt <= '0;
                    for (int i = 0; i < CHANNELS; i = i + 1) begin
                        max_mem[i] <= '0;
                    end
                    state <= STATE_READ;
                end

                STATE_READ: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        // First step seeds the running maximum; later steps
                        // compare. Both operate on the ReLU'd value, so the
                        // result is identical to ReLU followed by max pooling.
                        if (step_cnt == 0) begin
                            max_mem[in_c_cnt] <= relu_data;
                        end else if (relu_data > max_mem[in_c_cnt]) begin
                            max_mem[in_c_cnt] <= relu_data;
                        end

                        if (in_c_cnt == CHANNELS - 1) begin
                            in_c_cnt <= '0;
                            step_cnt <= step_cnt + 1;

                            if (s_axis_tlast) begin
                                state <= STATE_WRITE;
                            end
                        end else begin
                            in_c_cnt <= in_c_cnt + 1;
                        end
                    end
                end

                STATE_WRITE: begin
                    if (m_axis_tvalid && m_axis_tready) begin
                        if (out_c_cnt == CHANNELS - 1) begin
                            out_c_cnt <= '0;
                            for (int i = 0; i < CHANNELS; i = i + 1) begin
                                max_mem[i] <= '0;
                            end
                            state <= STATE_READ;
                        end else begin
                            out_c_cnt <= out_c_cnt + 1;
                        end
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
