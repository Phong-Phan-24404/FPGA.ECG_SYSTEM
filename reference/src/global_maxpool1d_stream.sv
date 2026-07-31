// d:\fpga_cc\FPGA_CNN\rtl\src\global_maxpool1d_stream.sv
// Synthesizable SystemVerilog module for global 1D max pooling.
// Reduces temporal dimension (STEPS) to 1 step by tracking max per channel.
// Automatically serializes output channels when input tlast asserts.

`timescale 1ns / 1ps

module global_maxpool1d_stream #(
    parameter int DATA_WIDTH = 16,
    parameter int CHANNELS   = 256,
    parameter int STEPS      = 38
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

    // Initial negative value for signed comparative initialization (-32768)
    localparam logic signed [DATA_WIDTH-1:0] InitialMin = (1'sb1 << (DATA_WIDTH - 1));

    // FSM States
    typedef enum logic [1:0] {
        STATE_IDLE  = 2'b00,
        STATE_READ  = 2'b01,
        STATE_WRITE = 2'b10
    } state_t;

    state_t state;

    // Counters
    logic [$clog2(CHANNELS):0] in_c_cnt;
    logic [15:0]               step_cnt;
    logic [$clog2(CHANNELS):0] out_c_cnt;

    // Memory to store running max values
    logic signed [DATA_WIDTH-1:0] max_mem [CHANNELS];

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
                max_mem[i] = InitialMin;
            end
        end else begin
            case (state)
                STATE_IDLE: begin
                    in_c_cnt  <= '0;
                    step_cnt  <= '0;
                    out_c_cnt <= '0;
                    for (int i = 0; i < CHANNELS; i = i + 1) begin
                        max_mem[i] = InitialMin;
                    end
                    state <= STATE_READ;
                end

                STATE_READ: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        // Perform running comparison
                        // If it's the first step of the frame, write directly to initialize
                        if (step_cnt == 0) begin
                            max_mem[in_c_cnt] <= s_axis_tdata;
                        end else begin
                            if ($signed(s_axis_tdata) > max_mem[in_c_cnt]) begin
                                max_mem[in_c_cnt] <= s_axis_tdata;
                            end
                        end

                        // Increment channels and step
                        if (in_c_cnt == CHANNELS - 1) begin
                            in_c_cnt <= '0;
                            step_cnt <= step_cnt + 1;

                            // Check for frame termination on last beat
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
                            // Complete and reinitialize memory for next frame
                            for (int i = 0; i < CHANNELS; i = i + 1) begin
                                max_mem[i] = InitialMin;
                            end
                            state <= STATE_READ;
                            step_cnt <= '0;
                            in_c_cnt  <= '0;
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
