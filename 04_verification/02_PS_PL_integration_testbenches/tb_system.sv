`timescale 1ns / 1ps

// Full-block-design smoke and one-vector CNN datapath test.
// The design has no external ports, so the Zynq MPSoC VIP is used as the
// processor to access every AXI-Lite peripheral and its DDR memory model.
module tb_system;

    localparam logic [39:0] INTC_BASE = 40'h00_8000_0000;
    localparam logic [39:0] DMA_BASE  = 40'h00_8001_0000;
    localparam logic [39:0] CNN_BASE  = 40'h00_8002_0000;
    localparam logic [39:0] INPUT_DDR = 40'h00_0010_0000;
    localparam logic [39:0] OUTPUT_DDR = 40'h00_0020_0000;

    localparam int INPUT_SAMPLES  = 187;
    localparam int OUTPUT_SAMPLES = 5;

    // MM2S is 32 bits and the subset converter selects tdata[15:0], so each
    // signed Q8.8 input sample occupies the low half of one 32-bit DDR word.
    localparam int MM2S_BYTES = INPUT_SAMPLES * 4;
    localparam int S2MM_BYTES = OUTPUT_SAMPLES * 2;

    // The DMA's 32-bit master reaches PS DDR through a 128-bit slave port, so
    // SmartConnect's upsizer fetches whole 16-byte words and the datamover
    // fetches whole 64-byte bursts. A 748-byte transfer is therefore read as
    // 768 bytes, and the tail has to be initialised memory or the Zynq model
    // returns X and its AXI protocol checker fires. A driver gets this for
    // free from a page-aligned coherent buffer; the testbench pads it here.
    localparam int INPUT_BURST_WORDS  = 16;
    localparam int INPUT_WORDS_PADDED =
        ((INPUT_SAMPLES + INPUT_BURST_WORDS - 1) / INPUT_BURST_WORDS)
        * INPUT_BURST_WORDS;

    localparam logic [39:0] MM2S_DMACR  = DMA_BASE + 40'h00;
    localparam logic [39:0] MM2S_DMASR  = DMA_BASE + 40'h04;
    localparam logic [39:0] MM2S_SA     = DMA_BASE + 40'h18;
    localparam logic [39:0] MM2S_LENGTH = DMA_BASE + 40'h28;
    localparam logic [39:0] S2MM_DMACR  = DMA_BASE + 40'h30;
    localparam logic [39:0] S2MM_DMASR  = DMA_BASE + 40'h34;
    localparam logic [39:0] S2MM_DA     = DMA_BASE + 40'h48;
    localparam logic [39:0] S2MM_LENGTH = DMA_BASE + 40'h58;

    logic [32767:0] data;
    logic [1:0]    resp;
    logic [31:0]   value;
    logic [15:0]   input_samples [0:INPUT_SAMPLES-1];
    logic [15:0]   golden_logits [0:OUTPUT_SAMPLES-1];
    int            errors = 0;

    // Per-hop AXI4-Stream handshake counts, so a stalled run says *where* it
    // stalled. Declared here because the watchdog below reports them too.
    int mm2s_beats;
    int cnn_in_beats;
    int cnn_out_beats;
    int s2mm_beats;

    // CNN AXI4-Stream master snoop: the accelerator's own result.
    logic [15:0] cnn_logits [0:OUTPUT_SAMPLES-1];
    int          cnn_tlast_beat;

    // S2MM write-channel snoop: the bytes the DMA puts in PS memory.
    logic [7:0]  s2mm_image [0:S2MM_BYTES-1];
    logic [39:0] s2mm_wr_addr;
    int          s2mm_bytes_written;

    system_wrapper dut ();

    task automatic read32(
        input  logic [39:0] address,
        input  string       item,
        output logic [31:0] result
    );
        begin
            data = '0;
            resp = 'x;
            dut.system_i.zynq_ultra_ps_e_0.inst.read_data(
                address, 4, data, resp
            );
            result = data[31:0];
            if (resp !== 2'b00 || $isunknown(result)) begin
                $error("%s read failed: address=0x%010h resp=%b data=0x%08h",
                       item, address, resp, result);
                errors++;
            end else begin
                $display("[TB] %-12s @ 0x%010h = 0x%08h", item, address, result);
            end
        end
    endtask

    task automatic load_input_ddr;
        logic [31:0] sample_word;
        begin
            for (int i = 0; i < INPUT_WORDS_PADDED; i++) begin
                // Words past the frame are the burst-alignment padding the
                // datamover over-reads and discards; they only have to be
                // defined.
                sample_word = (i < INPUT_SAMPLES)
                              ? {16'h0000, input_samples[i]} : 32'h0000_0000;
                data = '0;
                data[31:0] = sample_word;
                dut.system_i.zynq_ultra_ps_e_0.inst.write_mem(
                    data, INPUT_DDR + (i * 4), 4
                );
            end

            // A small backdoor read verifies byte ordering before DMA starts.
            data = '0;
            dut.system_i.zynq_ultra_ps_e_0.inst.read_mem(INPUT_DDR, 4, data);
            if (data[31:0] !== {16'h0000, input_samples[0]}) begin
                $error("DDR input preload mismatch: expected 0x%08h, got 0x%08h",
                       {16'h0000, input_samples[0]}, data[31:0]);
                errors++;
            end
        end
    endtask

    task automatic clear_output_ddr;
        begin
            data = '1;
            dut.system_i.zynq_ultra_ps_e_0.inst.write_mem(
                data, OUTPUT_DDR, 12
            );
        end
    endtask

    // The accelerator's own output: the five logits it drove onto its
    // AXI4-Stream master, captured beat by beat by the snoop below.
    task automatic check_cnn_stream;
        begin
            if (cnn_out_beats != OUTPUT_SAMPLES) begin
                $error("CNN produced %0d output beats, expected %0d",
                       cnn_out_beats, OUTPUT_SAMPLES);
                errors++;
            end
            if (cnn_tlast_beat != OUTPUT_SAMPLES) begin
                $error("CNN asserted TLAST on beat %0d, expected beat %0d",
                       cnn_tlast_beat, OUTPUT_SAMPLES);
                errors++;
            end
            for (int i = 0; i < OUTPUT_SAMPLES; i++) begin
                $display("[TB] CNN stream logit[%0d] expected=0x%04h actual=0x%04h",
                         i, golden_logits[i], cnn_logits[i]);
                if (cnn_logits[i] !== golden_logits[i]) begin
                    $error("CNN stream logit[%0d] mismatch", i);
                    errors++;
                end
            end
        end
    endtask

    // What the DMA actually deposited in PS memory, reconstructed from the
    // S2MM write channel. This is the last point the design is responsible
    // for: past the PS AXI slave port the data belongs to the Zynq model.
    task automatic check_s2mm_writes;
        logic [15:0] actual;
        begin
            if (s2mm_bytes_written != S2MM_BYTES) begin
                $error("S2MM wrote %0d bytes to 0x%010h, expected %0d",
                       s2mm_bytes_written, OUTPUT_DDR, S2MM_BYTES);
                errors++;
            end
            for (int i = 0; i < OUTPUT_SAMPLES; i++) begin
                actual = {s2mm_image[i*2 + 1], s2mm_image[i*2]};
                $display("[TB] DDR write logit[%0d] expected=0x%04h actual=0x%04h",
                         i, golden_logits[i], actual);
                if (actual !== golden_logits[i]) begin
                    $error("S2MM logit[%0d] written to DDR mismatch", i);
                    errors++;
                end
            end
        end
    endtask

    // Informational only. The Zynq MPSoC VIP serves backdoor read_mem() from
    // the same DDR array its PL slave ports write into, but a PL write that it
    // has accepted and acknowledged (correct address, data and byte strobes,
    // confirmed on ddrc's own wr_req/wr_addr/wr_data/wr_strb) never appears in
    // that array. Backdoor reads of DMA output therefore return the prefill
    // pattern and cannot be used as a pass criterion; check_s2mm_writes above
    // is the real check. Backdoor *writes* are unaffected, which is why the
    // input frame reaches the CNN correctly.
    task automatic report_ddr_backdoor;
        begin
            for (int word_index = 0; word_index < 3; word_index++) begin
                data = '0;
                dut.system_i.zynq_ultra_ps_e_0.inst.read_mem(
                    OUTPUT_DDR + (word_index * 4), 4, data
                );
                $display("[TB] (info) VIP backdoor DDR word[%0d] = 0x%08h",
                         word_index, data[31:0]);
            end
        end
    endtask

    task automatic write32(
        input logic [39:0] address,
        input logic [31:0] write_value,
        input string       item
    );
        begin
            data = '0;
            data[31:0] = write_value;
            resp = 'x;
            dut.system_i.zynq_ultra_ps_e_0.inst.write_data(
                address, 4, data, resp
            );
            if (resp !== 2'b00) begin
                $error("%s write failed: address=0x%010h resp=%b",
                       item, address, resp);
                errors++;
            end
        end
    endtask

    initial begin : test
        $display("[TB] Starting full-system AXI and CNN datapath test");

        // The simulation launcher stages these paths before XSim elaborates.
        $readmemh("datasets/golden_fixed/test_vectors_hex/sample_0/input.hex",
                  input_samples);
        $readmemh("datasets/golden_fixed/test_vectors_hex/sample_0/logits.hex",
                  golden_logits);

        // A missing datasets/ directory makes $readmemh a silent no-op and
        // leaves these arrays -- and every CNN weight ROM, which resolves the
        // same relative path -- at X. The run then takes minutes and compares
        // garbage. Refuse at time 0 instead.
        if ($isunknown({input_samples[0], input_samples[INPUT_SAMPLES-1],
                        golden_logits[0], golden_logits[OUTPUT_SAMPLES-1]}))
            $fatal(1, {"[TB] sample_0 vectors did not load. Stage them under ",
                       "<sim dir>/datasets/golden_fixed/ before elaboration ",
                       "(run_tb_system_sim.tcl does this)."});

        // This BD stops the AXI clock while clk_wiz is in reset, so the VIP
        // cannot observe 16 clock edges during reset; keep that check a warning.
        dut.system_i.zynq_ultra_ps_e_0.inst.M_AXI_HPM0_LPD.master.IF
            .set_xilinx_reset_check_to_warn();
        dut.system_i.zynq_ultra_ps_e_0.inst.S_AXI_HPC0_FPD.slave.IF
            .set_xilinx_reset_check_to_warn();

        // Reset sequence recommended for the Zynq UltraScale+ PS VIP.
        dut.system_i.zynq_ultra_ps_e_0.inst.por_srstb_reset(1'b0);
        dut.system_i.zynq_ultra_ps_e_0.inst.fpga_soft_reset(32'h1);
        #2000; // More than 16 cycles of the 100 MHz PL clock.
        dut.system_i.zynq_ultra_ps_e_0.inst.por_srstb_reset(1'b1);
        dut.system_i.zynq_ultra_ps_e_0.inst.fpga_soft_reset(32'h0);

        // Waiting on the generated clock and reset also verifies clock/reset IP.
        wait (dut.system_i.proc_sys_reset_2_peripheral_aresetn === 1'b1);
        repeat (5) @(posedge dut.system_i.clk_wiz_0_clk_out2);

        // Reach every AXI-Lite slave through PS HPM0 LPD and SmartConnect.
        read32(INTC_BASE + 40'h00, "INTC ISR", value);
        read32(MM2S_DMACR, "MM2S DMACR", value);
        read32(MM2S_DMASR, "MM2S DMASR", value);
        read32(S2MM_DMACR, "S2MM DMACR", value);
        read32(S2MM_DMASR, "S2MM DMASR", value);
        read32(CNN_BASE  + 40'h00, "CNN CTRL", value);
        read32(CNN_BASE  + 40'h04, "CNN STATUS", value);

        // Prove both AXI read and write paths with a harmless CNN register.
        write32(CNN_BASE + 40'h08, 32'h0000_0001, "CNN GIE");
        read32 (CNN_BASE + 40'h08, "CNN GIE", value);
        if (value !== 32'h0000_0001) begin
            $error("CNN GIE readback mismatch: expected 1, got 0x%08h", value);
            errors++;
        end
        write32(CNN_BASE + 40'h08, 32'h0000_0000, "CNN GIE restore");

        // Put one real golden ECG frame in PS DDR and clear the result area.
        load_input_ddr();
        clear_output_ddr();

        // Reset both simple-mode DMA channels. The reset bit self-clears.
        write32(MM2S_DMACR, 32'h0000_0004, "MM2S reset");
        write32(S2MM_DMACR, 32'h0000_0004, "S2MM reset");
        repeat (20) @(posedge dut.system_i.clk_wiz_0_clk_out2);

        // Arm receive first so the CNN output can never be backpressured by an
        // unconfigured S2MM channel. Bit 12 enables completion interrupt.
        write32(S2MM_DA,     OUTPUT_DDR[31:0], "S2MM destination");
        write32(S2MM_DMACR,  32'h0000_1001,    "S2MM run");
        write32(S2MM_LENGTH, S2MM_BYTES,       "S2MM length");

        // Enable CNN completion interrupt, clear stale status, and start it.
        write32(CNN_BASE + 40'h08, 32'h1, "CNN GIE");
        write32(CNN_BASE + 40'h0C, 32'h1, "CNN IER");
        write32(CNN_BASE + 40'h10, 32'h1, "CNN ISR clear");
        write32(CNN_BASE + 40'h00, 32'h1, "CNN start");

        // Program MM2S last. Writing LENGTH launches the input transaction.
        write32(MM2S_SA,     INPUT_DDR[31:0], "MM2S source");
        write32(MM2S_DMACR,  32'h0000_1001,   "MM2S run");
        write32(MM2S_LENGTH, MM2S_BYTES,      "MM2S length");

        $display("[TB] DMA started: %0d input bytes, %0d output bytes",
                 MM2S_BYTES, S2MM_BYTES);

        // A real-weight inference is a little over 10^5 clock cycles. Wait on
        // the real DMA completion interrupt rather than polling AXI-Lite.
        wait (dut.system_i.axi_dma_0_s2mm_introut === 1'b1);
        $display("[TB] S2MM completion interrupt at %0t", $time);

        // The Zynq VIP can assert the DMA completion interrupt in the same
        // simulation time slot in which its DDR backdoor model commits the
        // final AXI write.  Allow those pending writes to settle before using
        // read_mem(), otherwise a faster CNN can expose stale prefill data.
        repeat (4) @(posedge dut.system_i.clk_wiz_0_clk_out2);

        read32(MM2S_DMASR, "MM2S final", value);
        if (!value[1] || value[6:4] != 3'b000) begin
            $error("MM2S did not finish cleanly: DMASR=0x%08h", value);
            errors++;
        end
        read32(S2MM_DMASR, "S2MM final", value);
        if (!value[1] || value[6:4] != 3'b000) begin
            $error("S2MM did not finish cleanly: DMASR=0x%08h", value);
            errors++;
        end
        read32(CNN_BASE + 40'h04, "CNN final", value);
        if (!value[0]) begin
            $error("CNN done bit was not set: STATUS=0x%08h", value);
            errors++;
        end

        check_cnn_stream();
        check_s2mm_writes();
        report_ddr_backdoor();

        if (errors == 0)
            $display("[TB] PASS: full PS-DDR/DMA/CNN datapath matches golden sample 0");
        else
            $fatal(1, "[TB] FAIL: %0d error(s)", errors);

        $finish;
    end

    // Prevent a missing clock or an AXI deadlock from hanging simulation.
    // One inference is ~103 k clocks (1.03 ms at 100 MHz), measured by
    // tb_system_top_taps on the same RTL, so 20 ms is 20x the real frame and
    // still bounds a deadlock to a few minutes of wall clock.
    initial begin : watchdog
        #20ms;
        $display("[TB] TIMEOUT state: mm2s=%0d cnn_in=%0d cnn_out=%0d s2mm=%0d core_state=%0d CNN_IRQ=%b S2MM_IRQ=%b",
                 mm2s_beats, cnn_in_beats, cnn_out_beats, s2mm_beats,
                 dut.system_i.CNN_wrapper_0.inst.u_ecg_accel_top.state,
                 dut.system_i.CNN_wrapper_0_interrupt,
                 dut.system_i.axi_dma_0_s2mm_introut);
        $fatal(1, "[TB] TIMEOUT");
    end

    // Full Zynq block-design simulation is slow, and an inference is a few
    // hundred thousand clocks. Count the stream handshakes at each hop so a
    // stalled run says *where* it stalled instead of only that it timed out.
    always @(posedge dut.system_i.clk_wiz_0_clk_out2) begin
        if (dut.system_i.proc_sys_reset_2_peripheral_aresetn !== 1'b1) begin
            mm2s_beats   <= 0;
            cnn_in_beats  <= 0;
            cnn_out_beats <= 0;
            s2mm_beats    <= 0;
        end else begin
            if (dut.system_i.axi_dma_0_M_AXIS_MM2S_TVALID &&
                dut.system_i.axi_dma_0_M_AXIS_MM2S_TREADY)
                mm2s_beats <= mm2s_beats + 1;
            if (dut.system_i.axis_data_fifo_0_M_AXIS_TVALID &&
                dut.system_i.axis_data_fifo_0_M_AXIS_TREADY)
                cnn_in_beats <= cnn_in_beats + 1;
            if (dut.system_i.CNN_wrapper_0_m_axis_TVALID &&
                dut.system_i.CNN_wrapper_0_m_axis_TREADY)
                cnn_out_beats <= cnn_out_beats + 1;
            if (dut.system_i.axis_subset_converter_1_M_AXIS_TVALID &&
                dut.system_i.axis_subset_converter_1_M_AXIS_TREADY)
                s2mm_beats <= s2mm_beats + 1;
        end
    end

    // Capture the CNN's output beats and the beat TLAST lands on.
    always @(posedge dut.system_i.clk_wiz_0_clk_out2) begin
        if (dut.system_i.proc_sys_reset_2_peripheral_aresetn !== 1'b1) begin
            cnn_tlast_beat <= 0;
        end else if (dut.system_i.CNN_wrapper_0_m_axis_TVALID &&
                     dut.system_i.CNN_wrapper_0_m_axis_TREADY) begin
            if (cnn_out_beats < OUTPUT_SAMPLES)
                cnn_logits[cnn_out_beats] <= dut.system_i.CNN_wrapper_0_m_axis_TDATA;
            if (dut.system_i.CNN_wrapper_0_m_axis_TLAST)
                cnn_tlast_beat <= cnn_out_beats + 1;
        end
    end

    // Rebuild the DDR image the S2MM channel writes. Blocking assignments keep
    // the running address usable by the W beats handled in the same evaluation.
    always @(posedge dut.system_i.clk_wiz_0_clk_out2) begin
        int unsigned byte_index;
        if (dut.system_i.proc_sys_reset_2_peripheral_aresetn !== 1'b1) begin
            s2mm_wr_addr       = '0;
            s2mm_bytes_written = 0;
        end else begin
            if (dut.system_i.axi_dma_0_M_AXI_S2MM_AWVALID &&
                dut.system_i.axi_dma_0_M_AXI_S2MM_AWREADY)
                s2mm_wr_addr = {8'h00, dut.system_i.axi_dma_0_M_AXI_S2MM_AWADDR};

            if (dut.system_i.axi_dma_0_M_AXI_S2MM_WVALID &&
                dut.system_i.axi_dma_0_M_AXI_S2MM_WREADY) begin
                for (int b = 0; b < 4; b++) begin
                    if (dut.system_i.axi_dma_0_M_AXI_S2MM_WSTRB[b]) begin
                        // Unsigned wrap puts any address outside the output
                        // buffer far above S2MM_BYTES, so one test covers both
                        // ends of the range.
                        byte_index = (s2mm_wr_addr + b) - OUTPUT_DDR;
                        if (byte_index < S2MM_BYTES) begin
                            s2mm_image[byte_index] =
                                dut.system_i.axi_dma_0_M_AXI_S2MM_WDATA[b*8 +: 8];
                            s2mm_bytes_written = s2mm_bytes_written + 1;
                        end
                    end
                end
                s2mm_wr_addr = s2mm_wr_addr + 4;
            end
        end
    end

    initial begin : progress_report
        forever begin
            #1ms;
            $display("[TB] progress: t=%0t mm2s=%0d cnn_in=%0d cnn_out=%0d s2mm=%0d core_state=%0d CNN_IRQ=%b S2MM_IRQ=%b",
                     $time, mm2s_beats, cnn_in_beats, cnn_out_beats, s2mm_beats,
                     dut.system_i.CNN_wrapper_0.inst.u_ecg_accel_top.state,
                     dut.system_i.CNN_wrapper_0_interrupt,
                     dut.system_i.axi_dma_0_s2mm_introut);
        end
    end

endmodule
