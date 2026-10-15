// AXI4-Stream decoupling FIFO — Phase 2, CP2-3.
//
// WHY THIS EXISTS
// ---------------
// conv1d_parallel_stream drives `s_axis_tready = (state == STATE_READ)`, so a
// convolution engine is DEAF to its input for the whole of its compute and
// write phase. For conv6 that is ~2 312 of every ~2 568 cycles.
//
// The 2026-09-15 handshake census measured the consequence: conv6 is the
// pipeline rate limiter, is never blocked by anything downstream (0.0 %), and
// spends 41.8 % of the frame — 70 653 cycles — STARVED. Its producer conv5 is
// faster per step (1 858 vs 2 589 cycles) and could always stay a step ahead,
// but while conv6 is deaf conv5 has nowhere to put results, so it stalls and
// only begins producing the next step once conv6 reopens. conv6 then waits.
//
// Placing this FIFO between them lets conv5 build step N+1 while conv6 computes
// step N. Nothing about the arithmetic changes: a FIFO preserves beat order,
// beat count and TLAST association exactly, so bit-exactness is structural
// rather than something to re-argue.
//
// SIZING
// ------
// DEPTH is measured, not guessed. conv6 consumes one input step of
// IN_CHANNELS beats per output step; conv5 produces that step in 1 808 cycles
// while conv6 is busy for 2 312. One step of storage therefore covers the whole
// deaf window, so DEPTH = IN_CHANNELS (256 for conv6) is sufficient.
//
// The storage is forced to distributed RAM. After DEC-06 only ~17 of 144 BRAM
// tiles remain, and 256 x 17 bits is a few dozen LUTs as distributed memory
// versus a whole BRAM tile.

`timescale 1ns / 1ps

module axis_stream_fifo #(
    parameter int DATA_WIDTH = 16,
    // Must be a power of two so the pointers wrap naturally.
    parameter int DEPTH      = 256
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

    localparam int PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

`ifndef SYNTHESIS
    initial begin
        if (DEPTH < 2) begin
            $fatal(1, "axis_stream_fifo requires DEPTH >= 2");
        end
        if ((DEPTH & (DEPTH - 1)) != 0) begin
            $fatal(1, "axis_stream_fifo requires DEPTH to be a power of two");
        end
    end
`endif

    // TLAST travels in the same word as its data so the two can never be
    // separated by the buffer.
    // Icarus 11 warns on the Verible-preferred [DEPTH] spelling, matching the
    // convention used by the weight ROMs -- see docs/lint_waivers.md.
    // verilog_lint: waive unpacked-dimensions-range-ordering
    (* ram_style = "distributed" *) logic [DATA_WIDTH:0] mem [0:DEPTH-1];

    // `level` counts 0..DEPTH inclusive, so it needs one bit more than a
    // pointer. FIFO_FULL is a correctly-sized constant: writing the comparison
    // as PTR_W'(DEPTH) would truncate 256 to 0 for an 8-bit pointer and leave
    // the FIFO permanently "full".
    localparam logic [PTR_W:0] FIFO_FULL = DEPTH;

    logic [PTR_W-1:0] wr_ptr;
    logic [PTR_W-1:0] rd_ptr;
    logic [PTR_W:0]   level;

    logic do_write;
    logic do_read;

    // AXI4-Stream requires that TVALID never depends on TREADY. Both flags come
    // from `level` alone, so neither direction creates a combinational path
    // through the other and the FIFO cannot deadlock against its neighbours.
    assign s_axis_tready = (level != FIFO_FULL);
    assign m_axis_tvalid = (level != '0);

    assign do_write = s_axis_tvalid && s_axis_tready;
    assign do_read  = m_axis_tvalid && m_axis_tready;

    // Distributed RAM reads asynchronously, which gives first-word fall-through
    // without the extra output register a block-RAM FIFO would need. The read
    // data is only meaningful when m_axis_tvalid is high.
    assign m_axis_tdata = mem[rd_ptr][DATA_WIDTH-1:0];
    assign m_axis_tlast = mem[rd_ptr][DATA_WIDTH];

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            level  <= '0;
            // mem is deliberately not reset: no location is ever read before it
            // has been written, because m_axis_tvalid is low while level == 0.
        end else begin
            if (do_write) begin
                mem[wr_ptr] <= {s_axis_tlast, s_axis_tdata};
                wr_ptr      <= wr_ptr + 1'b1;
            end

            if (do_read) begin
                rd_ptr <= rd_ptr + 1'b1;
            end

            if (do_write && !do_read) begin
                level <= level + 1'b1;
            end else if (do_read && !do_write) begin
                level <= level - 1'b1;
            end
        end
    end

endmodule
