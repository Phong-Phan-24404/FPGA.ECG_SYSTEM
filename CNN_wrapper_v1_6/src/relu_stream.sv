`timescale 1ns / 1ps

module relu_stream #(
    parameter int DATA_WIDTH = 16,
    parameter int REGISTERED = 1  // 1 = 1-cycle registered, 0 = 0-cycle combinational
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

    generate
        if (REGISTERED == 1) begin : gen_registered
            logic [DATA_WIDTH-1:0] reg_tdata;
            logic                  reg_tvalid;
            logic                  reg_tlast;

            always_ff @(posedge aclk) begin
                if (!aresetn) begin
                    reg_tvalid <= 1'b0;
                    reg_tdata  <= '0;
                    reg_tlast  <= 1'b0;
                end else if (s_axis_tready) begin
                    reg_tvalid <= s_axis_tvalid;
                    reg_tdata  <= (s_axis_tdata[DATA_WIDTH-1] == 1'b1) ? '0 : s_axis_tdata;
                    reg_tlast  <= s_axis_tlast;
                end
            end

            assign s_axis_tready = !reg_tvalid || m_axis_tready;
            assign m_axis_tdata  = reg_tdata;
            assign m_axis_tvalid = reg_tvalid;
            assign m_axis_tlast  = reg_tlast;
        end else begin : gen_combinational
            assign s_axis_tready = m_axis_tready;
            assign m_axis_tvalid = s_axis_tvalid;
            assign m_axis_tdata  = (s_axis_tdata[DATA_WIDTH-1] == 1'b1) ? '0 : s_axis_tdata;
            assign m_axis_tlast  = s_axis_tlast;
        end
    endgenerate

endmodule
