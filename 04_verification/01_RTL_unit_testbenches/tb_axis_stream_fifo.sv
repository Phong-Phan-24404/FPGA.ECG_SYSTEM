// Unit testbench for axis_stream_fifo (Phase 2, CP2-3).
//
// The FIFO's whole justification is that it preserves the stream exactly while
// decoupling producer from consumer, so this testbench proves precisely that:
// every beat comes out in order, exactly once, with its TLAST still attached,
// under adversarial independent stalling on both ports. It also proves the
// buffer really does decouple (it fills while the sink is closed) and that a
// mid-stream reset flushes it, since the accelerator's reset-recovery tests
// depend on that.

`timescale 1ns / 1ps

module tb_axis_stream_fifo;

    localparam int DATA_WIDTH = 16;
    localparam int DEPTH      = 256;
    localparam int N_BEATS    = 4000;

    logic                  aclk = 0;
    logic                  aresetn = 0;

    logic [DATA_WIDTH-1:0] s_tdata;
    logic                  s_tvalid;
    logic                  s_tready;
    logic                  s_tlast;

    logic [DATA_WIDTH-1:0] m_tdata;
    logic                  m_tvalid;
    logic                  m_tready;
    logic                  m_tlast;

    always #5 aclk = ~aclk;

    axis_stream_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH)
    ) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast)
    );

    int    seed = 32'h5EED_1234;
    int    sent = 0;
    int    recv = 0;
    int    fails = 0;
    int    max_level = 0;
    bit    checking = 0;

    // Expected payload is the beat index, so an out-of-order or dropped beat is
    // caught immediately rather than at the end.
    task automatic check_beat(input int idx, input logic [DATA_WIDTH-1:0] got,
                              input logic got_last);
        logic [DATA_WIDTH-1:0] want;
        logic                  want_last;
        want      = DATA_WIDTH'(idx);
        want_last = (idx == N_BEATS - 1);
        if (got !== want) begin
            fails = fails + 1;
            if (fails <= 5) begin
                $display("[FAIL] beat %0d: expected 0x%04h, got 0x%04h", idx, want, got);
            end
        end
        if (got_last !== want_last) begin
            fails = fails + 1;
            if (fails <= 5) begin
                $display("[FAIL] beat %0d: expected tlast=%0b, got %0b", idx, want_last, got_last);
            end
        end
    endtask

    // Producer: offers a beat whenever a coin flip allows, so TVALID is
    // deliberately intermittent and independent of the consumer.
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_tvalid <= 1'b0;
            s_tdata  <= '0;
            s_tlast  <= 1'b0;
        end else if (checking) begin
            if (!(s_tvalid && !s_tready)) begin
                if (sent < N_BEATS && ($dist_uniform(seed, 0, 99) < 70)) begin
                    s_tvalid <= 1'b1;
                    s_tdata  <= DATA_WIDTH'(sent);
                    s_tlast  <= (sent == N_BEATS - 1);
                    sent      = sent + 1;
                end else begin
                    s_tvalid <= 1'b0;
                end
            end
        end
    end

    // Consumer: accepts on an independent coin flip.
    always @(posedge aclk) begin
        if (!aresetn) begin
            m_tready <= 1'b0;
        end else if (checking) begin
            m_tready <= ($dist_uniform(seed, 0, 99) < 55);
        end
    end

    // Scoreboard and occupancy watch.
    always @(posedge aclk) begin
        if (aresetn && checking) begin
            if (m_tvalid && m_tready) begin
                check_beat(recv, m_tdata, m_tlast);
                recv = recv + 1;
            end
            if (int'(dut.level) > max_level) begin
                max_level = int'(dut.level);
            end
            if (int'(dut.level) > DEPTH) begin
                fails = fails + 1;
                $display("[FAIL] occupancy %0d exceeded DEPTH %0d", int'(dut.level), DEPTH);
            end
        end
    end

    // Decoupling proof: hold the sink closed and confirm the FIFO absorbs a
    // whole conv6 input step without stalling the producer. This is the exact
    // behaviour CP2-3 needs and the reason the module exists.
    task automatic prove_decoupling;
        int absorbed;
        absorbed = 0;
        m_tready = 1'b0;
        s_tlast  = 1'b0;
        for (int i = 0; i < DEPTH; i = i + 1) begin
            s_tdata  = DATA_WIDTH'(i);
            s_tvalid = 1'b1;
            @(posedge aclk);
            if (s_tready) begin
                absorbed = absorbed + 1;
            end else begin
                i = i - 1;   // retry this beat
            end
        end
        s_tvalid = 1'b0;
        @(posedge aclk);
        if (absorbed != DEPTH) begin
            fails = fails + 1;
            $display("[FAIL] absorbed only %0d of %0d beats with the sink closed", absorbed, DEPTH);
        end
        if (s_tready !== 1'b0) begin
            fails = fails + 1;
            $display("[FAIL] FIFO still accepting after DEPTH beats with the sink closed");
        end
        $display("[INFO] absorbed %0d beats with the sink held closed, then asserted full", absorbed);

        // Drain it again so the main pass starts from empty.
        m_tready = 1'b1;
        while (m_tvalid) @(posedge aclk);
        m_tready = 1'b0;
        @(posedge aclk);
        if (dut.level !== '0) begin
            fails = fails + 1;
            $display("[FAIL] FIFO not empty after draining");
        end
    endtask

    // Reset proof: fill partially, reset mid-stream, confirm the buffer is
    // empty and presents nothing. The accelerator's mid-frame reset recovery
    // tests rely on this.
    task automatic prove_reset_flush;
        m_tready = 1'b0;
        for (int i = 0; i < 37; i = i + 1) begin
            s_tdata  = DATA_WIDTH'(i);
            s_tvalid = 1'b1;
            @(posedge aclk);
            while (!s_tready) @(posedge aclk);
        end
        s_tvalid = 1'b0;
        @(posedge aclk);
        if (!m_tvalid) begin
            fails = fails + 1;
            $display("[FAIL] FIFO shows nothing to read after 37 writes");
        end
        aresetn = 1'b0;
        repeat (3) @(posedge aclk);
        aresetn = 1'b1;
        @(posedge aclk);
        if (m_tvalid !== 1'b0) begin
            fails = fails + 1;
            $display("[FAIL] FIFO still presents data after reset");
        end
        if (dut.level !== '0) begin
            fails = fails + 1;
            $display("[FAIL] FIFO occupancy not cleared by reset");
        end
        $display("[INFO] mid-stream reset flushed the buffer");
    endtask

    initial begin
        s_tvalid = 1'b0;
        s_tdata  = '0;
        s_tlast  = 1'b0;
        m_tready = 1'b0;

        repeat (4) @(posedge aclk);
        aresetn = 1'b1;
        repeat (2) @(posedge aclk);

        $display("==================================================");
        $display("Running tb_axis_stream_fifo (DEPTH=%0d, %0d beats)", DEPTH, N_BEATS);
        $display("==================================================");

        prove_decoupling();
        prove_reset_flush();

        // Main randomized pass.
        checking = 1;
        wait (recv == N_BEATS);
        repeat (4) @(posedge aclk);
        checking = 0;

        $display("  beats sent %0d, received %0d, peak occupancy %0d of %0d",
                 sent, recv, max_level, DEPTH);

        $display("==================================================");
        if (fails == 0 && recv == N_BEATS && sent == N_BEATS) begin
            $display("[PASS] axis_stream_fifo preserves order, count and TLAST under");
            $display("       independent producer/consumer stalling, decouples a full");
            $display("       DEPTH burst, and flushes on reset. [SUCCESS]");
        end else begin
            $display("[FAIL] tb_axis_stream_fifo: %0d problems, %0d/%0d beats received",
                     fails, recv, N_BEATS);
        end
        $display("==================================================");
        $finish;
    end

    initial begin
        #5000000;
        $display("[FAIL] tb_axis_stream_fifo timeout: received %0d of %0d beats", recv, N_BEATS);
        $finish;
    end

endmodule
