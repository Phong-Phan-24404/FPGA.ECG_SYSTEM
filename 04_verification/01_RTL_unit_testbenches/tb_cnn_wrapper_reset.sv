// Mid-frame reset recovery for CNN_wrapper, driven the way software drives it.
// Phase 1, CP-6.
//
// tb_ecg_accel_top_reset proves the accelerator core recovers. This proves the
// AXI wrapper around it does too — the CSR state machine, the sticky done bit,
// the interrupt and the input gate all have to come back to their reset values,
// and the frame that follows has to be bit-exact.
//
// Sequence:
//   1. reset, enable interrupts, start, drive part of a frame;
//   2. assert s_axi_aresetn mid-frame;
//   3. after release, check STATUS/ISR/interrupt are back to their reset values
//      and the input port is gated again (no start pulse survived the reset);
//   4. start a fresh frame and require the five golden logits, bit for bit.

`timescale 1ns / 1ps

module tb_cnn_wrapper_reset;

    localparam int DATA_WIDTH         = 16;
    localparam int C_S_AXI_DATA_WIDTH = 32;
    localparam int C_S_AXI_ADDR_WIDTH = 6;
    localparam time CLK_PERIOD        = 10ns;

    localparam logic [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CTRL   = 6'h00;
    localparam logic [C_S_AXI_ADDR_WIDTH-1:0] ADDR_STATUS = 6'h04;
    localparam logic [C_S_AXI_ADDR_WIDTH-1:0] ADDR_GIE    = 6'h08;
    localparam logic [C_S_AXI_ADDR_WIDTH-1:0] ADDR_IER    = 6'h0C;
    localparam logic [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ISR    = 6'h10;

    localparam int INPUT_SAMPLES     = ecg_params_pkg::CONV1_IN_STEPS;
    localparam int NUM_LOGITS        = ecg_params_pkg::FC3_OUT;
    localparam int ABORT_AFTER_BEATS = 130;
    localparam SAMPLE_DIR = "datasets/golden_fixed/test_vectors_hex/sample_0/";

    logic s_axi_aclk;
    logic s_axi_aresetn;

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

    logic [DATA_WIDTH-1:0]             s_axis_tdata;
    logic                              s_axis_tvalid;
    logic                              s_axis_tready;
    logic                              s_axis_tlast;

    logic [DATA_WIDTH-1:0]             m_axis_tdata;
    logic                              m_axis_tvalid;
    logic                              m_axis_tready;
    logic                              m_axis_tlast;

    logic                              interrupt;

    logic [DATA_WIDTH-1:0] input_mem       [0:INPUT_SAMPLES-1];
    logic [DATA_WIDTH-1:0] expected_logits [0:NUM_LOGITS-1];

    int errors       = 0;
    int out_beat_cnt = 0;
    logic monitor_active = 1'b0;

    CNN_wrapper #(
        .DATA_WIDTH(DATA_WIDTH),
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

    initial begin
        s_axi_aclk = 1'b0;
        forever #(CLK_PERIOD/2) s_axi_aclk = ~s_axi_aclk;
    end

    task automatic tb_check(input bit condition, input string message);
        begin
            if (!condition) begin
                errors++;
                $display("[FAIL] %s", message);
            end else begin
                $display("[PASS] %s", message);
            end
        end
    endtask

    task automatic axi_lite_write(input logic [C_S_AXI_ADDR_WIDTH-1:0] addr,
                                  input logic [31:0] data);
        begin
            @(negedge s_axi_aclk);
            s_axi_awaddr  <= addr;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wstrb   <= 4'hF;
            s_axi_wvalid  <= 1'b1;
            s_axi_bready  <= 1'b1;

            fork
                begin
                    while (!(s_axi_awvalid && s_axi_awready)) @(posedge s_axi_aclk);
                    @(negedge s_axi_aclk);
                    s_axi_awvalid <= 1'b0;
                end
                begin
                    while (!(s_axi_wvalid && s_axi_wready)) @(posedge s_axi_aclk);
                    @(negedge s_axi_aclk);
                    s_axi_wvalid <= 1'b0;
                end
            join

            while (!s_axi_bvalid) @(posedge s_axi_aclk);
            @(negedge s_axi_aclk);
            s_axi_bready <= 1'b0;
        end
    endtask

    task automatic axi_lite_read(input logic [C_S_AXI_ADDR_WIDTH-1:0] addr,
                                 output logic [31:0] data);
        begin
            @(negedge s_axi_aclk);
            s_axi_araddr  <= addr;
            s_axi_arvalid <= 1'b1;
            s_axi_rready  <= 1'b1;

            while (!(s_axi_arvalid && s_axi_arready)) @(posedge s_axi_aclk);
            @(negedge s_axi_aclk);
            s_axi_arvalid <= 1'b0;

            while (!s_axi_rvalid) @(posedge s_axi_aclk);
            data = s_axi_rdata;
            @(negedge s_axi_aclk);
            s_axi_rready <= 1'b0;
        end
    endtask

    // Same ordering as tb_conv1d_parallel_golden: present, then edge, then
    // hold until the handshake actually completes.
    task automatic axis_send_beat(input logic [DATA_WIDTH-1:0] data,
                                  input logic last);
        begin
            s_axis_tdata  <= data;
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= last;
            @(posedge s_axi_aclk);
            while (!s_axis_tready) @(posedge s_axi_aclk);
        end
    endtask

    always @(posedge s_axi_aclk) begin
        if (s_axi_aresetn && monitor_active && m_axis_tvalid && m_axis_tready) begin
            if (out_beat_cnt < NUM_LOGITS) begin
                if (m_axis_tdata !== expected_logits[out_beat_cnt]) begin
                    $display("[FAIL] post-reset logit %0d: expected 0x%04h, got 0x%04h",
                             out_beat_cnt, expected_logits[out_beat_cnt], m_axis_tdata);
                    errors++;
                end
            end else begin
                $display("[FAIL] output beat %0d beyond the expected %0d logits",
                         out_beat_cnt, NUM_LOGITS);
                errors++;
            end
            out_beat_cnt++;
        end
    end

    initial begin
        #900000000;
        $display("[FAIL] tb_cnn_wrapper_reset timeout at beat %0d/%0d",
                 out_beat_cnt, NUM_LOGITS);
        $finish;
    end

    initial begin
        logic [31:0] rd;

        s_axi_aresetn = 1'b0;
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
        m_axis_tready = 1'b1;

        $readmemh({SAMPLE_DIR, "input.hex"},  input_mem);
        $readmemh({SAMPLE_DIR, "logits.hex"}, expected_logits);

        repeat (10) @(posedge s_axi_aclk);
        s_axi_aresetn = 1'b1;
        repeat (5) @(posedge s_axi_aclk);

        $display("==================================================");
        $display("Running tb_cnn_wrapper_reset");
        $display("==================================================");

        // ---- start a frame, then abandon it mid-stream -------------------
        axi_lite_write(ADDR_GIE, 32'h0000_0001);
        axi_lite_write(ADDR_IER, 32'h0000_0001);
        axi_lite_write(ADDR_CTRL, 32'h0000_0001);

        $display("[TB] driving %0d of %0d input beats, then asserting reset",
                 ABORT_AFTER_BEATS, INPUT_SAMPLES);
        for (int i = 0; i < ABORT_AFTER_BEATS; i++) begin
            axis_send_beat(input_mem[i], 1'b0);
        end
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
        @(posedge s_axi_aclk);

        s_axi_aresetn = 1'b0;
        repeat (10) @(posedge s_axi_aclk);
        tb_check(m_axis_tvalid == 1'b0, "m_axis_tvalid is low while in reset");
        tb_check(interrupt == 1'b0,     "interrupt is low while in reset");
        s_axi_aresetn = 1'b1;
        repeat (5) @(posedge s_axi_aclk);

        // ---- CSR state must be back to its reset values ------------------
        axi_lite_read(ADDR_STATUS, rd);
        tb_check(rd[0] == 1'b0, "STATUS.done_sticky is 0 after mid-frame reset");
        tb_check(rd[1] == 1'b1, "STATUS.idle is 1 after mid-frame reset");
        tb_check(rd[2] == 1'b0, "STATUS.busy is 0 after mid-frame reset");
        axi_lite_read(ADDR_ISR, rd);
        tb_check(rd[0] == 1'b0, "ISR[0] is 0 after mid-frame reset");
        axi_lite_read(ADDR_GIE, rd);
        tb_check(rd[0] == 1'b0, "GIE is back to its reset value");
        axi_lite_read(ADDR_CTRL, rd);
        tb_check(rd[0] == 1'b0, "CTRL.run_enable is 0 - no start survived the reset");
        tb_check(interrupt == 1'b0, "interrupt is deasserted after mid-frame reset");

        // Input must be gated again: the pre-reset start pulse must not persist.
        s_axis_tvalid <= 1'b1;
        s_axis_tdata  <= 16'h1234;
        repeat (5) @(posedge s_axi_aclk);
        #1;
        tb_check(s_axis_tready == 1'b0,
                 "s_axis_tready is low after reset until software starts again");
        s_axis_tvalid <= 1'b0;
        s_axis_tdata  <= '0;
        @(posedge s_axi_aclk);

        // ---- a full frame after the reset must be bit-exact ---------------
        $display("[TB] full frame after the reset must produce the golden logits");
        axi_lite_write(ADDR_GIE, 32'h0000_0001);
        axi_lite_write(ADDR_IER, 32'h0000_0001);
        axi_lite_write(ADDR_CTRL, 32'h0000_0001);

        out_beat_cnt   = 0;
        monitor_active = 1'b1;

        for (int i = 0; i < INPUT_SAMPLES; i++) begin
            axis_send_beat(input_mem[i], i == (INPUT_SAMPLES - 1));
        end
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
        @(posedge s_axi_aclk);

        while (out_beat_cnt < NUM_LOGITS) @(posedge s_axi_aclk);
        repeat (10) @(posedge s_axi_aclk);
        monitor_active = 1'b0;

        tb_check(out_beat_cnt == NUM_LOGITS,
                 "post-reset frame produced exactly 5 logits");
        tb_check(interrupt == 1'b1, "interrupt asserts on the post-reset frame");

        axi_lite_read(ADDR_STATUS, rd);
        tb_check(rd[0] == 1'b1, "STATUS.done_sticky is 1 after the post-reset frame");

        $display("==================================================");
        if (errors == 0) begin
            $display("[PASS] CNN_wrapper recovers from a mid-frame reset and the next frame is bit-exact. [SUCCESS]");
        end else begin
            $display("[FAIL] tb_cnn_wrapper_reset: %0d error(s)", errors);
        end
        $display("==================================================");
        $finish;
    end

endmodule
