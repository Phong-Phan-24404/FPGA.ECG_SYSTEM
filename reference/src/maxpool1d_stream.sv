// d:\fpga_cc\FPGA_CNN\rtl\src\maxpool1d_stream.sv
// Synthesizable SystemVerilog module for temporal stride-2 MaxPool1d.
// Accumulates even steps in local memory, performs max on odd steps,
// and asserts output tlast at the correct frame boundary.

`timescale 1ns / 1ps

module maxpool1d_stream #(
    parameter int DATA_WIDTH  = 16,
    parameter int CHANNELS    = 16,
    parameter int KERNEL_SIZE = 2,
    parameter int STRIDE      = 2,
    parameter int IN_STEPS    = 179
)(
    input  logic                  aclk,
    input  logic                  aresetn,

    // AXI-Stream Slave (Input)
    input  logic [DATA_WIDTH-1:0] s_axis_tdata,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,
    input  logic                  s_axis_tlast,

    // AXI-Stream Master (Output)
    output logic [DATA_WIDTH-1:0] m_axis_tdata,
    output logic                  m_axis_tvalid,
    input  logic                  m_axis_tready,
    output logic                  m_axis_tlast
);

    // Number of outputs steps
    localparam int OutSteps = IN_STEPS / 2;

    // FSM States
    typedef enum logic [1:0] {
        STATE_IDLE      = 2'b00,
        STATE_EVEN      = 2'b01, // Read and store even steps
        STATE_ODD_COMP  = 2'b10, // Read odd steps and compute/output max
        STATE_DISCARD   = 2'b11  // Consume and discard remainder steps
    } state_t;

    state_t state;

    // Counters
    logic [$clog2(CHANNELS):0] c_cnt;
    logic [15:0]              step_cnt;

    // Buffer to hold even step values
    logic signed [DATA_WIDTH-1:0] even_buf [CHANNELS];

    // Flow control assignment
    always_comb begin
        if (state == STATE_EVEN || state == STATE_DISCARD) begin
            s_axis_tready = 1'b1;
            m_axis_tvalid = 1'b0;
        end else if (state == STATE_ODD_COMP) begin
            s_axis_tready = m_axis_tready;
            m_axis_tvalid = s_axis_tvalid;
        end else begin
            s_axis_tready = 1'b0;
            m_axis_tvalid = 1'b0;
        end
    end

    // Compute max
    logic signed [DATA_WIDTH-1:0] in_val;
    logic signed [DATA_WIDTH-1:0] prev_val;
    logic signed [DATA_WIDTH-1:0] max_val;

    assign in_val   = s_axis_tdata;
    assign prev_val = even_buf[c_cnt];
    assign max_val  = (in_val > prev_val) ? in_val : prev_val;

    assign m_axis_tdata = max_val;

    // TLAST is asserted on the last channel of the last valid output step
    // The last valid output step is step_cnt == (2 * OUT_STEPS - 1)
    assign m_axis_tlast = (state == STATE_ODD_COMP) &&
                          (c_cnt == CHANNELS - 1) &&
                          (step_cnt == (2 * OutSteps) - 1);

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            state    <= STATE_IDLE;
            c_cnt    <= '0;
            step_cnt <= '0;
            for (int i = 0; i < CHANNELS; i = i + 1) begin
                even_buf[i] <= '0;
            end
        end else begin
            case (state)
                STATE_IDLE: begin
                    c_cnt    <= '0;
                    step_cnt <= '0;
                    state    <= STATE_EVEN;
                end

                STATE_EVEN: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        even_buf[c_cnt] <= s_axis_tdata;
                        if (c_cnt == CHANNELS - 1) begin
                            c_cnt <= '0;
                            // Check if this even step was the last step of the frame (discarded step)
                            if (s_axis_tlast || (step_cnt == IN_STEPS - 1)) begin
                                state <= STATE_IDLE;
                            end else begin
                                step_cnt <= step_cnt + 1;
                                state    <= STATE_ODD_COMP;
                            end
                        end else begin
                            c_cnt <= c_cnt + 1;
                        end
                    end
                end

                STATE_ODD_COMP: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        if (c_cnt == CHANNELS - 1) begin
                            c_cnt <= '0;
                            if (s_axis_tlast || (step_cnt == IN_STEPS - 1)) begin
                                state <= STATE_IDLE;
                            end else begin
                                step_cnt <= step_cnt + 1;
                                // If next step is the last step and it is even (odd total steps),
                                // it will be discarded. We transition to STATE_DISCARD.
                                if (step_cnt + 1 == IN_STEPS - 1) begin
                                    state <= STATE_DISCARD;
                                end else begin
                                    state <= STATE_EVEN;
                                end
                            end
                        end else begin
                            c_cnt <= c_cnt + 1;
                        end
                    end
                end

                STATE_DISCARD: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        if (c_cnt == CHANNELS - 1) begin
                            c_cnt <= '0;
                            state <= STATE_IDLE; // Frame terminates
                        end else begin
                            c_cnt <= c_cnt + 1;
                        end
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
