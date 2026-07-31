// CNN_wrapper_tb.sv
// Self-checking protocol/register testbench for CNN_wrapper.
// This testbench verifies:
//   1. active-low reset behavior
//   2. AXI4-Lite register read/write access
//   3. AXI-Stream input gating before software start
//   4. start -> stream frame -> done/interrupt flow
//   5. output AXI-Stream acceptance with light backpressure
//
// It does not check numerical CNN classification accuracy. Add a golden-scoreboard
// later if you have known input samples and expected CNN outputs.

`timescale 1ns / 1ps

module CNN_wrapper_tb;

    localparam int DATA_WIDTH         = 16;
    localparam bit REGISTERED_MATH    = 0;
    localparam int C_S_AXI_DATA_WIDTH = 32;
    localparam int C_S_AXI_ADDR_WIDTH = 6;

    localparam time CLK_PERIOD = 10ns;

    // AXI4-Lite byte addresses.
    localparam logic [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CTRL   = 6'h00;
    localparam logic [C_S_AXI_ADDR_WIDTH-1:0] ADDR_STATUS = 6'h04;
    localparam logic [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GIE    = 6'h08;
    localparam logic [C_S_AXI_ADDR_WIDTH-1:0] ADDR_IER    = 6'h0C;
    localparam logic [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ISR    = 6'h10;

    // Tune these for your CNN latency and frame size.
    localparam int INPUT_SAMPLES      = 256;
    localparam int AXIS_READY_TIMEOUT = 10000;
    localparam int DONE_TIMEOUT       = 200000;

    // Shared clock/reset.
    logic s_axi_aclk;
    logic s_axi_aresetn;

    // AXI4-Lite slave control interface.
    logic [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr;
    logic [2:0]                        s_axi_awprot;
    logic                              s_axi_awvalid;
    logic                              s_axi_awready;

    logic [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata;
    logic [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb;
    logic                              s_axi_wvalid;
    logic                              s_axi_wready;

    logic [1:0]                        s_axi_bresp;
    logic                              s_axi_bvalid;
    logic                              s_axi_bready;

    logic [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr;
    logic [2:0]                        s_axi_arprot;
    logic                              s_axi_arvalid;
    logic                              s_axi_arready;

    logic [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata;
    logic [1:0]                        s_axi_rresp;
    logic                              s_axi_rvalid;
    logic                              s_axi_rready;

    // AXI4-Stream slave input to CNN.
    logic [DATA_WIDTH-1:0]             s_axis_tdata;
    logic                              s_axis_tvalid;
    logic                              s_axis_tready;
    logic                              s_axis_tlast;

    // AXI4-Stream master output from CNN.
    logic [DATA_WIDTH-1:0]             m_axis_tdata;
    logic                              m_axis_tvalid;
    logic                              m_axis_tready;
    logic                              m_axis_tlast;

    logic                              interrupt;

    int unsigned error_count;
    int unsigned output_count;
    logic        output_tlast_seen;
    logic [DATA_WIDTH-1:0] last_output_word;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    CNN_wrapper #(
        .DATA_WIDTH(DATA_WIDTH),
        .REGISTERED_MATH(REGISTERED_MATH),
        .C_S_AXI_DATA_WIDTH(C_S_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)
    ) dut (
        .s_axi_aclk(s_axi_aclk),
        .s_axi_aresetn(s_axi_aresetn),

        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),

        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),

        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),

        .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),

        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),

        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),

        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),

        .interrupt(interrupt)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial begin
        s_axi_aclk = 1'b0;
        forever #(CLK_PERIOD/2) s_axi_aclk = ~s_axi_aclk;
    end

    // -------------------------------------------------------------------------
    // Utility tasks
    // -------------------------------------------------------------------------
    task automatic tb_check(input bit condition, input string message);
        begin
            if (!condition) begin
                error_count++;
                $error("[FAIL] %s", message);
            end else begin
                $display("[PASS] %s", message);
            end
        end
    endtask

    task automatic init_signals;
        begin
            s_axi_awaddr  = '0;
            s_axi_awprot  = 3'b000;
            s_axi_awvalid = 1'b0;
            s_axi_wdata   = '0;
            s_axi_wstrb   = '0;
            s_axi_wvalid  = 1'b0;
            s_axi_bready  = 1'b0;
            s_axi_araddr  = '0;
            s_axi_arprot  = 3'b000;
            s_axi_arvalid = 1'b0;
            s_axi_rready  = 1'b0;

            s_axis_tdata  = '0;
            s_axis_tvalid = 1'b0;
            s_axis_tlast  = 1'b0;

        end
    endtask

    task automatic apply_reset;
        begin
            init_signals();
            s_axi_aresetn = 1'b0;
            repeat (10) @(posedge s_axi_aclk);
            s_axi_aresetn = 1'b1;
            repeat (5) @(posedge s_axi_aclk);
        end
    endtask

    task automatic axi_lite_write(
        input logic [C_S_AXI_ADDR_WIDTH-1:0] addr,
        input logic [31:0]                   data
    );
        bit aw_done;
        bit w_done;
        int unsigned cycles;
        begin
            aw_done = 1'b0;
            w_done  = 1'b0;
            cycles  = 0;

            @(posedge s_axi_aclk);
            #1;
            s_axi_awaddr  <= addr;
            s_axi_awprot  <= 3'b000;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wstrb   <= 4'hF;
            s_axi_wvalid  <= 1'b1;
            s_axi_bready  <= 1'b1;

            while (!(aw_done && w_done)) begin
                @(posedge s_axi_aclk);
                #1;
                cycles++;

                if (s_axi_awvalid && s_axi_awready) begin
                    s_axi_awvalid <= 1'b0;
                    aw_done = 1'b1;
                end

                if (s_axi_wvalid && s_axi_wready) begin
                    s_axi_wvalid <= 1'b0;
                    w_done = 1'b1;
                end

                if (cycles > 100) begin
                    $fatal(1, "AXI4-Lite write address/data timeout at addr 0x%0h", addr);
                end
            end

            cycles = 0;
            while (!s_axi_bvalid) begin
                @(posedge s_axi_aclk);
                #1;
                cycles++;
                if (cycles > 100) begin
                    $fatal(1, "AXI4-Lite write response timeout at addr 0x%0h", addr);
                end
            end

            tb_check(s_axi_bresp == 2'b00, "AXI4-Lite write response is OKAY");

            @(posedge s_axi_aclk);
            #1;
            s_axi_bready <= 1'b0;
            s_axi_wstrb  <= '0;
            s_axi_wdata  <= '0;
            s_axi_awaddr <= '0;
        end
    endtask

    task automatic axi_lite_read(
        input  logic [C_S_AXI_ADDR_WIDTH-1:0] addr,
        output logic [31:0]                   data
    );
        int unsigned cycles;
        begin
            cycles = 0;

            @(posedge s_axi_aclk);
            #1;
            s_axi_araddr  <= addr;
            s_axi_arprot  <= 3'b000;
            s_axi_arvalid <= 1'b1;
            s_axi_rready  <= 1'b1;

            while (s_axi_arvalid) begin
                @(posedge s_axi_aclk);
                #1;
                cycles++;

                if (s_axi_arvalid && s_axi_arready) begin
                    s_axi_arvalid <= 1'b0;
                end

                if (cycles > 100) begin
                    $fatal(1, "AXI4-Lite read address timeout at addr 0x%0h", addr);
                end
            end

            cycles = 0;
            while (!s_axi_rvalid) begin
                @(posedge s_axi_aclk);
                #1;
                cycles++;
                if (cycles > 100) begin
                    $fatal(1, "AXI4-Lite read data timeout at addr 0x%0h", addr);
                end
            end

            data = s_axi_rdata;
            tb_check(s_axi_rresp == 2'b00, "AXI4-Lite read response is OKAY");

            @(posedge s_axi_aclk);
            #1;
            s_axi_rready <= 1'b0;
            s_axi_araddr <= '0;
        end
    endtask

    task automatic axis_send_beat(
        input logic [DATA_WIDTH-1:0] data,
        input logic                  last
    );
        int unsigned cycles;
        begin
            cycles = 0;

            @(posedge s_axi_aclk);
            #1;
            s_axis_tdata  <= data;
            s_axis_tlast  <= last;
            s_axis_tvalid <= 1'b1;

            while (!(s_axis_tvalid && s_axis_tready)) begin
                @(posedge s_axi_aclk);
                #1;
                cycles++;
                if (cycles > AXIS_READY_TIMEOUT) begin
                    $fatal(1, "AXI-Stream input ready timeout. Beat data=0x%0h last=%0b", data, last);
                end
            end

            @(posedge s_axi_aclk);
            #1;
            s_axis_tvalid <= 1'b0;
            s_axis_tlast  <= 1'b0;
            s_axis_tdata  <= '0;
        end
    endtask

    task automatic axis_send_frame(input int unsigned sample_count);
        logic [DATA_WIDTH-1:0] sample;
        begin
            $display("Sending AXI-Stream frame with %0d samples", sample_count);
            for (int unsigned i = 0; i < sample_count; i++) begin
                sample = i;
                axis_send_beat(sample, i == (sample_count - 1));
            end
            $display("Finished AXI-Stream input frame");
        end
    endtask

    task automatic wait_for_done;
        logic [31:0] status;
        int unsigned cycles;
        begin
            cycles = 0;
            while (!interrupt && !output_tlast_seen) begin
                @(posedge s_axi_aclk);
                #1;
                cycles++;
                if (cycles > DONE_TIMEOUT) begin
                    axi_lite_read(ADDR_STATUS, status);
                    $fatal(1,
                        "Done timeout. STATUS=0x%08h interrupt=%0b output_count=%0d output_tlast_seen=%0b",
                        status, interrupt, output_count, output_tlast_seen);
                end
            end

            // Give sticky status/interrupt registers one cycle to settle after core_done.
            repeat (2) @(posedge s_axi_aclk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Output ready driver and output monitor
    // -------------------------------------------------------------------------
    initial begin
        m_axis_tready = 1'b0;
        forever begin
            @(posedge s_axi_aclk);
            if (!s_axi_aresetn) begin
                m_axis_tready <= 1'b0;
            end else begin
                // Light backpressure pattern: ready for 6 cycles, stalled for 1 cycle.
                m_axis_tready <= (($time / CLK_PERIOD) % 7) != 0;
            end
        end
    end

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            output_count      <= 0;
            output_tlast_seen <= 1'b0;
            last_output_word  <= '0;
        end else if (m_axis_tvalid && m_axis_tready) begin
            output_count     <= output_count + 1;
            last_output_word <= m_axis_tdata;

            $display("Output beat %0d: data=0x%0h last=%0b time=%0t",
                     output_count, m_axis_tdata, m_axis_tlast, $time);

            if (m_axis_tlast) begin
                output_tlast_seen <= 1'b1;
            end
        end
    end

    // AXI-Stream master protocol check: data and TLAST must stay stable while stalled.
    property p_m_axis_stable_when_stalled;
        @(posedge s_axi_aclk) disable iff (!s_axi_aresetn)
        m_axis_tvalid && !m_axis_tready
        |=> m_axis_tvalid && $stable({m_axis_tdata, m_axis_tlast});
    endproperty

    assert property (p_m_axis_stable_when_stalled)
        else begin
            error_count++;
            $error("AXI-Stream master output changed while stalled");
        end

    // -------------------------------------------------------------------------
    // Main test
    // -------------------------------------------------------------------------
    initial begin
        logic [31:0] rd;

        error_count       = 0;
        output_count      = 0;
        output_tlast_seen = 1'b0;
        last_output_word  = '0;

        $display("============================================================");
        $display("Starting CNN_wrapper_tb");
        $display("============================================================");

        apply_reset();

        // Before software start, wrapper must block AXI-Stream input.
        s_axis_tdata  <= 16'h1234;
        s_axis_tlast  <= 1'b0;
        s_axis_tvalid <= 1'b1;
        repeat (5) @(posedge s_axi_aclk);
        #1;
        tb_check(s_axis_tready == 1'b0,
                 "s_axis_tready is low before CTRL start write");
        s_axis_tvalid <= 1'b0;
        s_axis_tdata  <= '0;

        // Check initial status after reset.
        axi_lite_read(ADDR_STATUS, rd);
        tb_check(rd[0] == 1'b0, "STATUS.done_sticky is 0 after reset");
        tb_check(rd[1] == 1'b1, "STATUS.idle is 1 after reset");
        tb_check(rd[2] == 1'b0, "STATUS.busy is 0 after reset");

        // Enable interrupt generation.
        axi_lite_write(ADDR_GIE, 32'h0000_0001);
        axi_lite_write(ADDR_IER, 32'h0000_0001);
        axi_lite_read(ADDR_GIE, rd);
        tb_check(rd[0] == 1'b1, "GIE[0] readback is 1");
        axi_lite_read(ADDR_IER, rd);
        tb_check(rd[0] == 1'b1, "IER[0] readback is 1");

        // Start accelerator. CTRL[0] is write-one-to-start.
        axi_lite_write(ADDR_CTRL, 32'h0000_0001);
        axi_lite_read(ADDR_CTRL, rd);
        tb_check(rd[0] == 1'b1, "CTRL.run_enable becomes 1 after start");

        // Drive one input frame and wait for output TLAST / interrupt.
        fork
            axis_send_frame(INPUT_SAMPLES);
            wait_for_done();
        join

        // Read final status.
        axi_lite_read(ADDR_STATUS, rd);
        tb_check(rd[0] == 1'b1, "STATUS.done_sticky is 1 after completion");
        tb_check(rd[1] == 1'b1, "STATUS.idle is 1 after completion");
        tb_check(rd[2] == 1'b0, "STATUS.busy is 0 after completion");
        tb_check(interrupt == 1'b1, "interrupt is asserted after done when GIE and IER are enabled");
        tb_check(output_count > 0, "at least one output beat was accepted");
        tb_check(output_tlast_seen == 1'b1, "output TLAST was observed");

        // Clear sticky done/interrupt through ISR W1C.
        axi_lite_write(ADDR_ISR, 32'h0000_0001);
        repeat (2) @(posedge s_axi_aclk);
        axi_lite_read(ADDR_STATUS, rd);
        tb_check(rd[0] == 1'b0, "STATUS.done_sticky clears after ISR W1C");
        axi_lite_read(ADDR_ISR, rd);
        tb_check(rd[0] == 1'b0, "ISR[0] clears after ISR W1C");
        tb_check(interrupt == 1'b0, "interrupt clears after ISR W1C");

        // After completion and clear, input should be gated again until next start.
        s_axis_tvalid <= 1'b1;
        s_axis_tdata  <= 16'h55AA;
        repeat (5) @(posedge s_axi_aclk);
        #1;
        tb_check(s_axis_tready == 1'b0,
                 "s_axis_tready returns low after frame completes and run_enable clears");
        s_axis_tvalid <= 1'b0;
        s_axis_tdata  <= '0;

        $display("============================================================");
        if (error_count == 0) begin
            $display("CNN_wrapper_tb PASSED");
        end else begin
            $display("CNN_wrapper_tb FAILED with %0d error(s)", error_count);
        end
        $display("Output beats accepted: %0d", output_count);
        $display("Last output word: 0x%0h", last_output_word);
        $display("============================================================");

        if (error_count != 0) begin
            $fatal(1, "Testbench failed");
        end

        $finish;
    end

endmodule
