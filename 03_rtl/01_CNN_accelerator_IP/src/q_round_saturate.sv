// d:\fpga_cc\FPGA_CNN\rtl\src\q_round_saturate.sv
// Synthesizable SystemVerilog module for Q-format rounding and saturation.
// Implements Round-Half-Up (Biased) rule: floor(x + 0.5) and clips to signed M-bit range.

`timescale 1ns / 1ps

module q_round_saturate #(
    parameter int N = 40,      // Input accumulator width
    parameter int M = 16,      // Output quantized width
    parameter int SHIFT = 14   // Right shift bits (e.g. Q18.22 -> Q8.8 = 14 shift)
)(
    input  logic signed [N-1:0] accumulator,
    output logic signed [M-1:0] saturated_out
);

    // Dynamic scale bounds
    localparam logic signed [N-1:0] MaxVal = (1 << (M - 1)) - 1;
    localparam logic signed [N-1:0] MinVal = -(1 << (M - 1));

    logic signed [N-1:0] half;
    logic signed [N-1:0] rounded_acc;

    generate
        if (SHIFT > 0) begin : gen_round
            assign half = (1 << (SHIFT - 1));
            assign rounded_acc = (accumulator + half) >>> SHIFT;
        end else begin : gen_bypass
            assign half = '0;
            assign rounded_acc = accumulator;
        end
    endgenerate

    // Saturation logic: clips to [-2^(M-1), 2^(M-1)-1]
    assign saturated_out = (rounded_acc > MaxVal) ? MaxVal[M-1:0] :
                           (rounded_acc < MinVal) ? MinVal[M-1:0] :
                           rounded_acc[M-1:0];

endmodule
