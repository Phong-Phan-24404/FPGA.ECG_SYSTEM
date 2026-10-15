// Fixed-count 64-bit banked synchronous ROM helpers for Phase-2 packed weights.
// Each bank is an independent memory so Vivado can map width/depth geometry
// directly to BRAM36 (or distributed ROM for explicitly tiny tables).

`timescale 1ns / 1ps

// Icarus Verilog 11.0 does not parse `parameter string` even in -g2012 mode.
// These filename parameters must therefore remain untyped for the authoritative
// simulator while retaining string values in Vivado.
// verilog_lint: waive-start explicit-parameter-storage-type

module ecg_dist_sync_rom #(
    parameter int WIDTH = 64,
    parameter int SIZE = 256,
    parameter FILE = ""
)(
    input  logic                    clk,
    input  logic [$clog2(SIZE)-1:0] addr,
    output logic [WIDTH-1:0]        data
);
    // Icarus 11 warns on the Verible-preferred [SIZE] spelling for $readmemh.
    // verilog_lint: waive unpacked-dimensions-range-ordering
    (* rom_style = "distributed" *) logic [WIDTH-1:0] mem [0:SIZE-1];
    initial begin
        if (FILE != "") begin
            $readmemh(FILE, mem);
        end
    end
    always_ff @(posedge clk) begin
        data <= mem[addr];
    end
endmodule

module ecg_sync_rom_select #(
    parameter int WIDTH = 64,
    parameter int SIZE = 256,
    parameter bit DISTRIBUTED = 0,
    parameter FILE = ""
)(
    input  logic                    clk,
    input  logic [$clog2(SIZE)-1:0] addr,
    output wire  [WIDTH-1:0]        data
);
    generate
        if (DISTRIBUTED) begin : gen_dist
            ecg_dist_sync_rom #(.WIDTH(WIDTH), .SIZE(SIZE), .FILE(FILE)) i_rom (
                .clk(clk), .addr(addr), .data(data)
            );
        end else begin : gen_block
            ecg_rom #(.WIDTH(WIDTH), .SIZE(SIZE), .FILE(FILE)) i_rom (
                .clk(clk), .addr(addr), .data(data)
            );
        end
    endgenerate
endmodule

module ecg_banked_rom_1 #(
    parameter int SIZE = 256,
    parameter bit DISTRIBUTED = 0,
    parameter FILE0 = ""
)(
    input  logic                    clk,
    input  logic [$clog2(SIZE)-1:0] addr,
    output wire  [63:0]       data
);
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE0)
    ) i_bank0 (
        .clk(clk), .addr(addr), .data(data[63:0])
    );
endmodule

module ecg_banked_rom_2 #(
    parameter int SIZE = 256,
    parameter bit DISTRIBUTED = 0,
    parameter FILE0 = "",
    parameter FILE1 = ""
)(
    input  logic                    clk,
    input  logic [$clog2(SIZE)-1:0] addr,
    output wire  [127:0]       data
);
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE0)
    ) i_bank0 (
        .clk(clk), .addr(addr), .data(data[63:0])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE1)
    ) i_bank1 (
        .clk(clk), .addr(addr), .data(data[127:64])
    );
endmodule

module ecg_banked_rom_4 #(
    parameter int SIZE = 256,
    parameter bit DISTRIBUTED = 0,
    parameter FILE0 = "",
    parameter FILE1 = "",
    parameter FILE2 = "",
    parameter FILE3 = ""
)(
    input  logic                    clk,
    input  logic [$clog2(SIZE)-1:0] addr,
    output wire  [255:0]       data
);
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE0)
    ) i_bank0 (
        .clk(clk), .addr(addr), .data(data[63:0])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE1)
    ) i_bank1 (
        .clk(clk), .addr(addr), .data(data[127:64])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE2)
    ) i_bank2 (
        .clk(clk), .addr(addr), .data(data[191:128])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE3)
    ) i_bank3 (
        .clk(clk), .addr(addr), .data(data[255:192])
    );
endmodule

// This intentionally shares the fixed-count bank-helper source file.
// verilog_lint: waive module-filename
module ecg_banked_rom_24 #(
    parameter int SIZE = 256,
    parameter bit DISTRIBUTED = 0,
    parameter FILE0 = "",
    parameter FILE1 = "",
    parameter FILE2 = "",
    parameter FILE3 = "",
    parameter FILE4 = "",
    parameter FILE5 = "",
    parameter FILE6 = "",
    parameter FILE7 = "",
    parameter FILE8 = "",
    parameter FILE9 = "",
    parameter FILE10 = "",
    parameter FILE11 = "",
    parameter FILE12 = "",
    parameter FILE13 = "",
    parameter FILE14 = "",
    parameter FILE15 = "",
    parameter FILE16 = "",
    parameter FILE17 = "",
    parameter FILE18 = "",
    parameter FILE19 = "",
    parameter FILE20 = "",
    parameter FILE21 = "",
    parameter FILE22 = "",
    parameter FILE23 = ""
)(
    input  logic                    clk,
    input  logic [$clog2(SIZE)-1:0] addr,
    output wire  [1535:0]       data
);
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE0)
    ) i_bank0 (
        .clk(clk), .addr(addr), .data(data[63:0])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE1)
    ) i_bank1 (
        .clk(clk), .addr(addr), .data(data[127:64])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE2)
    ) i_bank2 (
        .clk(clk), .addr(addr), .data(data[191:128])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE3)
    ) i_bank3 (
        .clk(clk), .addr(addr), .data(data[255:192])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE4)
    ) i_bank4 (
        .clk(clk), .addr(addr), .data(data[319:256])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE5)
    ) i_bank5 (
        .clk(clk), .addr(addr), .data(data[383:320])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE6)
    ) i_bank6 (
        .clk(clk), .addr(addr), .data(data[447:384])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE7)
    ) i_bank7 (
        .clk(clk), .addr(addr), .data(data[511:448])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE8)
    ) i_bank8 (
        .clk(clk), .addr(addr), .data(data[575:512])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE9)
    ) i_bank9 (
        .clk(clk), .addr(addr), .data(data[639:576])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE10)
    ) i_bank10 (
        .clk(clk), .addr(addr), .data(data[703:640])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE11)
    ) i_bank11 (
        .clk(clk), .addr(addr), .data(data[767:704])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE12)
    ) i_bank12 (
        .clk(clk), .addr(addr), .data(data[831:768])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE13)
    ) i_bank13 (
        .clk(clk), .addr(addr), .data(data[895:832])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE14)
    ) i_bank14 (
        .clk(clk), .addr(addr), .data(data[959:896])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE15)
    ) i_bank15 (
        .clk(clk), .addr(addr), .data(data[1023:960])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE16)
    ) i_bank16 (
        .clk(clk), .addr(addr), .data(data[1087:1024])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE17)
    ) i_bank17 (
        .clk(clk), .addr(addr), .data(data[1151:1088])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE18)
    ) i_bank18 (
        .clk(clk), .addr(addr), .data(data[1215:1152])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE19)
    ) i_bank19 (
        .clk(clk), .addr(addr), .data(data[1279:1216])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE20)
    ) i_bank20 (
        .clk(clk), .addr(addr), .data(data[1343:1280])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE21)
    ) i_bank21 (
        .clk(clk), .addr(addr), .data(data[1407:1344])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE22)
    ) i_bank22 (
        .clk(clk), .addr(addr), .data(data[1471:1408])
    );
    ecg_sync_rom_select #(
        .WIDTH(64), .SIZE(SIZE), .DISTRIBUTED(DISTRIBUTED),
        .FILE(FILE23)
    ) i_bank23 (
        .clk(clk), .addr(addr), .data(data[1535:1472])
    );
endmodule

// verilog_lint: waive-stop explicit-parameter-storage-type
