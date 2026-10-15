`timescale 1ns / 1ps

// Back-to-back inference and interrupt-controller coverage for the KV260 ECG
// block design.
//
// tb_system proves one inference end to end. Two things it says nothing about,
// and which PS software depends on, are covered here:
//
//   1. Restart. Every existing test asserts a full reset before each frame --
//      tb_system_top_regression does so between all five samples, precisely so
//      that residual state cannot hide. Nothing has ever run a second
//      inference on a design left in its post-frame state, which is exactly
//      what a driver does.
//   2. The interrupt path. tb_system waits on the raw axi_dma_0_s2mm_introut
//      net, so axi_intc_0 and the irq it drives into the PS are never
//      exercised. Every wait here goes through the controller instead, and its
//      status registers are checked.
//
// Frame 0 runs sample_0 and frame 1 runs sample_1 on the same un-reset design,
// so a stage that replays cached state instead of recomputing fails.
//
// Results are checked on the CNN's own AXI4-Stream master and on the bytes the
// DMA puts on its AXI write channel. The Zynq VIP's backdoor read_mem() cannot
// observe writes its PL slave port has accepted, so it is never a pass
// criterion; tb_system documents that in full.
module tb_system_irq_restart;

    localparam logic [39:0] INTC_BASE  = 40'h00_8000_0000;
    localparam logic [39:0] DMA_BASE   = 40'h00_8001_0000;
    localparam logic [39:0] CNN_BASE   = 40'h00_8002_0000;
    localparam logic [39:0] INPUT_DDR  = 40'h00_0010_0000;
    localparam logic [39:0] OUTPUT_DDR = 40'h00_0020_0000;

    // Each frame lands its result in its own page, so a frame that writes
    // nothing cannot pass on the previous frame's bytes.
    localparam logic [39:0] OUTPUT_STRIDE = 40'h00_0000_1000;

    localparam int NUM_FRAMES     = 2;
    localparam int INPUT_SAMPLES  = 187;
    localparam int OUTPUT_SAMPLES = 5;

    localparam int MM2S_BYTES = INPUT_SAMPLES * 4;
    localparam int S2MM_BYTES = OUTPUT_SAMPLES * 2;

    // The DMA's 32-bit master reaches PS DDR through a 128-bit slave port, so
    // SmartConnect's upsizer fetches whole 16-byte words and the datamover
    // fetches whole 64-byte bursts. A 748-byte transfer is therefore read as
    // 768 bytes and the tail must be initialised memory, or the Zynq model
    // returns X and its protocol checker fires -- possibly a frame later,
    // since the final over-read burst is still outstanding when the DMA
    // reports completion. A driver gets this for free from a page-aligned
    // coherent buffer; here the testbench pads it explicitly.
    localparam int INPUT_BURST_WORDS  = 16;
    localparam int INPUT_WORDS_PADDED =
        ((INPUT_SAMPLES + INPUT_BURST_WORDS - 1) / INPUT_BURST_WORDS)
        * INPUT_BURST_WORDS;

    // AXI INTC register map.
    localparam logic [39:0] INTC_ISR = INTC_BASE + 40'h00;
    localparam logic [39:0] INTC_IPR = INTC_BASE + 40'h04;
    localparam logic [39:0] INTC_IER = INTC_BASE + 40'h08;
    localparam logic [39:0] INTC_IAR = INTC_BASE + 40'h0C;
    localparam logic [39:0] INTC_IVR = INTC_BASE + 40'h18;
    localparam logic [39:0] INTC_MER = INTC_BASE + 40'h1C;

    // xlconcat_0 order: In0 = MM2S, In1 = S2MM, In2 = CNN.
    localparam int          IRQ_MM2S = 0;
    localparam int          IRQ_S2MM = 1;
    localparam int          IRQ_CNN  = 2;
    localparam logic [31:0] IRQ_ALL  = 32'h0000_0007;
    // The MM2S completion fires early -- the input FIFO absorbs the frame long
    // before the CNN has finished with it -- so end of frame is S2MM plus CNN.
    localparam logic [31:0] IRQ_DONE = (32'h1 << IRQ_S2MM) | (32'h1 << IRQ_CNN);

    localparam logic [31:0] MER_ME_HIE = 32'h0000_0003;

    localparam logic [39:0] MM2S_DMACR  = DMA_BASE + 40'h00;
    localparam logic [39:0] MM2S_DMASR  = DMA_BASE + 40'h04;
    localparam logic [39:0] MM2S_SA     = DMA_BASE + 40'h18;
    localparam logic [39:0] MM2S_LENGTH = DMA_BASE + 40'h28;
    localparam logic [39:0] S2MM_DMACR  = DMA_BASE + 40'h30;
    localparam logic [39:0] S2MM_DMASR  = DMA_BASE + 40'h34;
    localparam logic [39:0] S2MM_DA     = DMA_BASE + 40'h48;
    localparam logic [39:0] S2MM_LENGTH = DMA_BASE + 40'h58;

    localparam logic [39:0] CNN_CTRL   = CNN_BASE + 40'h00;
    localparam logic [39:0] CNN_STATUS = CNN_BASE + 40'h04;
    localparam logic [39:0] CNN_GIE    = CNN_BASE + 40'h08;
    localparam logic [39:0] CNN_IER    = CNN_BASE + 40'h0C;
    localparam logic [39:0] CNN_ISR    = CNN_BASE + 40'h10;

    localparam logic [31:0] DMASR_IOC = 32'h0000_1000;

    logic [32767:0] data;
    logic [1:0]     resp;
    logic [31:0]    value;
    int             errors = 0;

    logic [15:0] input_samples [0:NUM_FRAMES-1][0:INPUT_SAMPLES-1];
    logic [15:0] golden_logits [0:NUM_FRAMES-1][0:OUTPUT_SAMPLES-1];
    // XSim cannot $readmemh straight into a slice of a 2-D unpacked array.
    logic [15:0] load_input  [0:INPUT_SAMPLES-1];
    logic [15:0] load_logits [0:OUTPUT_SAMPLES-1];

    // Which frame the stream snoops below are attributing traffic to. Only
    // changed while every stream is idle.
    int frame_index = 0;

    // Per-frame captures.
    logic [15:0] cnn_logits   [0:NUM_FRAMES-1][0:OUTPUT_SAMPLES-1];
    int          cnn_in_beats [0:NUM_FRAMES-1];
    int          cnn_out_beats[0:NUM_FRAMES-1];
    int          cnn_tlast_beat[0:NUM_FRAMES-1];
    logic [7:0]  s2mm_image   [0:NUM_FRAMES-1][0:S2MM_BYTES-1];
    int          s2mm_bytes_written [0:NUM_FRAMES-1];
    logic [39:0] s2mm_wr_addr;

    system_wrapper dut ();

    wire aclk = dut.system_i.clk_wiz_0_clk_out2;
    wire ps_irq = dut.system_i.axi_intc_0_irq;   // == PS pl_ps_irq0

    // ------------------------------------------------------------------
    // AXI-Lite helpers
    // ------------------------------------------------------------------
    task automatic read32q(
        input  logic [39:0] address,
        output logic [31:0] result
    );
        begin
            data = '0;
            resp = 'x;
            dut.system_i.zynq_ultra_ps_e_0.inst.read_data(address, 4, data, resp);
            result = data[31:0];
            if (resp !== 2'b00 || $isunknown(result)) begin
                $error("read failed: address=0x%010h resp=%b data=0x%08h",
                       address, resp, result);
                errors++;
            end
        end
    endtask

    task automatic read32(
        input  logic [39:0] address,
        input  string       item,
        output logic [31:0] result
    );
        begin
            read32q(address, result);
            $display("[TB] %-14s @ 0x%010h = 0x%08h", item, address, result);
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
            dut.system_i.zynq_ultra_ps_e_0.inst.write_data(address, 4, data, resp);
            if (resp !== 2'b00) begin
                $error("%s write failed: address=0x%010h resp=%b",
                       item, address, resp);
                errors++;
            end
        end
    endtask

    task automatic load_input_ddr(input int frame);
        begin
            for (int i = 0; i < INPUT_WORDS_PADDED; i++) begin
                data = '0;
                // Words past the frame are the burst-alignment padding the
                // datamover over-reads and discards; they only have to be
                // defined.
                if (i < INPUT_SAMPLES)
                    data[31:0] = {16'h0000, input_samples[frame][i]};
                dut.system_i.zynq_ultra_ps_e_0.inst.write_mem(
                    data, INPUT_DDR + (i * 4), 4
                );
            end
            // Verify the whole frame, not just the first word: a partially
            // written or X buffer otherwise only shows up as an AXI protocol
            // violation thousands of cycles later.
            for (int i = 0; i < INPUT_SAMPLES; i++) begin
                data = '0;
                dut.system_i.zynq_ultra_ps_e_0.inst.read_mem(
                    INPUT_DDR + (i * 4), 4, data
                );
                if (data[31:0] !== {16'h0000, input_samples[frame][i]}) begin
                    $error("frame %0d DDR preload mismatch at word %0d (0x%010h): expected 0x%08h, got 0x%08h",
                           frame, i, INPUT_DDR + (i * 4),
                           {16'h0000, input_samples[frame][i]}, data[31:0]);
                    errors++;
                    if (errors > 5) break;
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Checks
    // ------------------------------------------------------------------
    task automatic expect32(
        input logic [31:0] actual,
        input logic [31:0] expected,
        input string       item
    );
        begin
            if (actual !== expected) begin
                $error("%s: expected 0x%08h, got 0x%08h", item, expected, actual);
                errors++;
            end
        end
    endtask

    // Wait until the controller reports every bit in mask pending, then confirm
    // it is driving the PS interrupt line. Polling IPL over AXI-Lite while the
    // accelerator streams is what a driver does, and it keeps control traffic
    // on the bus during inference.
    task automatic wait_for_intc(input logic [31:0] mask, input int frame);
        logic [31:0] ipr;
        int          polls;
        begin
            polls = 0;
            forever begin
                read32q(INTC_IPR, ipr);
                if ((ipr & mask) === mask) break;
                polls++;
                if (polls > 4000) begin
                    $error("frame %0d: INTC IPR stuck at 0x%08h, expected mask 0x%08h",
                           frame, ipr, mask);
                    errors++;
                    break;
                end
                repeat (500) @(posedge aclk);   // 5 us between polls
            end
            $display("[TB] frame %0d: INTC IPR = 0x%08h at %0t", frame, ipr, $time);
            if (ps_irq !== 1'b1) begin
                $error("frame %0d: INTC reports 0x%08h pending but the PS irq line is %b",
                       frame, ipr, ps_irq);
                errors++;
            end
        end
    endtask

    task automatic check_frame_results(input int frame);
        logic [15:0] actual;
        begin
            if (cnn_in_beats[frame] != INPUT_SAMPLES) begin
                $error("frame %0d: CNN consumed %0d input beats, expected %0d",
                       frame, cnn_in_beats[frame], INPUT_SAMPLES);
                errors++;
            end
            if (cnn_out_beats[frame] != OUTPUT_SAMPLES) begin
                $error("frame %0d: CNN produced %0d output beats, expected %0d",
                       frame, cnn_out_beats[frame], OUTPUT_SAMPLES);
                errors++;
            end
            if (cnn_tlast_beat[frame] != OUTPUT_SAMPLES) begin
                $error("frame %0d: CNN asserted TLAST on beat %0d, expected %0d",
                       frame, cnn_tlast_beat[frame], OUTPUT_SAMPLES);
                errors++;
            end
            if (s2mm_bytes_written[frame] != S2MM_BYTES) begin
                $error("frame %0d: S2MM wrote %0d bytes to 0x%010h, expected %0d",
                       frame, s2mm_bytes_written[frame],
                       OUTPUT_DDR + frame * OUTPUT_STRIDE, S2MM_BYTES);
                errors++;
            end
            for (int i = 0; i < OUTPUT_SAMPLES; i++) begin
                if (cnn_logits[frame][i] !== golden_logits[frame][i]) begin
                    $error("frame %0d (sample_%0d): CNN stream logit[%0d] expected 0x%04h, got 0x%04h",
                           frame, frame, i, golden_logits[frame][i],
                           cnn_logits[frame][i]);
                    errors++;
                end
                actual = {s2mm_image[frame][i*2 + 1], s2mm_image[frame][i*2]};
                if (actual !== golden_logits[frame][i]) begin
                    $error("frame %0d (sample_%0d): DDR logit[%0d] expected 0x%04h, got 0x%04h",
                           frame, frame, i, golden_logits[frame][i], actual);
                    errors++;
                end
            end
            $display("[TB] frame %0d (sample_%0d) logits: %04h %04h %04h %04h %04h",
                     frame, frame, cnn_logits[frame][0], cnn_logits[frame][1],
                     cnn_logits[frame][2], cnn_logits[frame][3],
                     cnn_logits[frame][4]);
        end
    endtask

    // Level-sensitive inputs: the sources must go quiet before the
    // acknowledge, or the controller latches them straight back.
    task automatic clear_all_interrupts(input int frame);
        begin
            write32(CNN_ISR,   32'h1,     "CNN ISR clear");
            write32(MM2S_DMASR, DMASR_IOC, "MM2S IOC clear");
            write32(S2MM_DMASR, DMASR_IOC, "S2MM IOC clear");
            write32(INTC_IAR,  IRQ_ALL,   "INTC IAR");

            repeat (20) @(posedge aclk);
            if (ps_irq !== 1'b0) begin
                $error("frame %0d: PS irq line still high after clearing every source",
                       frame);
                errors++;
            end
            read32(INTC_ISR, "INTC ISR", value);
            expect32(value, 32'h0, $sformatf("frame %0d INTC ISR after acknowledge", frame));
            read32(CNN_STATUS, "CNN STATUS", value);
            expect32(value, 32'h2, $sformatf("frame %0d CNN STATUS after clear (idle, not done)", frame));
        end
    endtask

    // ------------------------------------------------------------------
    // Test
    // ------------------------------------------------------------------
    initial begin : test
        logic [31:0] ipr_snapshot;
        int          beats_before_start;

        $display("[TB] Back-to-back inference and interrupt-controller test");

        for (int f = 0; f < NUM_FRAMES; f++) begin
            $readmemh($sformatf("datasets/golden_fixed/test_vectors_hex/sample_%0d/input.hex", f),
                      load_input);
            $readmemh($sformatf("datasets/golden_fixed/test_vectors_hex/sample_%0d/logits.hex", f),
                      load_logits);
            for (int i = 0; i < INPUT_SAMPLES; i++)
                input_samples[f][i] = load_input[i];
            for (int i = 0; i < OUTPUT_SAMPLES; i++)
                golden_logits[f][i] = load_logits[i];

            // A missing datasets/ directory makes $readmemh a silent no-op and
            // leaves every array -- and every CNN weight ROM, which resolves
            // the same relative path -- at X. The run then takes minutes and
            // compares garbage. Refuse at time 0 instead.
            if ($isunknown({input_samples[f][0], input_samples[f][INPUT_SAMPLES-1],
                            golden_logits[f][0], golden_logits[f][OUTPUT_SAMPLES-1]}))
                $fatal(1, {"[TB] sample_%0d vectors did not load. Stage them under ",
                           "<sim dir>/datasets/golden_fixed/ before elaboration ",
                           "(run_tb_system_irq_restart_sim.tcl does this)."}, f);
        end

        // The BD stops the AXI clock while clk_wiz is in reset, so the VIP
        // cannot observe 16 clock edges during reset; keep that a warning.
        dut.system_i.zynq_ultra_ps_e_0.inst.M_AXI_HPM0_LPD.master.IF
            .set_xilinx_reset_check_to_warn();
        dut.system_i.zynq_ultra_ps_e_0.inst.S_AXI_HPC0_FPD.slave.IF
            .set_xilinx_reset_check_to_warn();

        dut.system_i.zynq_ultra_ps_e_0.inst.por_srstb_reset(1'b0);
        dut.system_i.zynq_ultra_ps_e_0.inst.fpga_soft_reset(32'h1);
        #2000;
        dut.system_i.zynq_ultra_ps_e_0.inst.por_srstb_reset(1'b1);
        dut.system_i.zynq_ultra_ps_e_0.inst.fpga_soft_reset(32'h0);

        wait (dut.system_i.proc_sys_reset_2_peripheral_aresetn === 1'b1);
        repeat (5) @(posedge aclk);

        // ---- interrupt controller bring-up -------------------------------
        if (ps_irq !== 1'b0) begin
            $error("PS irq line is %b out of reset, expected 0", ps_irq);
            errors++;
        end
        read32(INTC_ISR, "INTC ISR", value);
        expect32(value, 32'h0, "INTC ISR out of reset");
        read32(INTC_MER, "INTC MER", value);
        expect32(value, 32'h0, "INTC MER out of reset");

        write32(INTC_IER, IRQ_ALL,    "INTC IER");
        read32 (INTC_IER, "INTC IER", value);
        expect32(value, IRQ_ALL, "INTC IER readback");
        write32(INTC_MER, MER_ME_HIE, "INTC MER");

        repeat (20) @(posedge aclk);
        if (ps_irq !== 1'b0) begin
            $error("PS irq line went high on enabling the controller with no source active");
            errors++;
        end

        // Reset both simple-mode DMA channels once, before the first frame.
        // Nothing resets them again: surviving frame 1 is the point.
        write32(MM2S_DMACR, 32'h0000_0004, "MM2S reset");
        write32(S2MM_DMACR, 32'h0000_0004, "S2MM reset");
        repeat (20) @(posedge aclk);
        write32(MM2S_DMACR, 32'h0000_1001, "MM2S run");
        write32(S2MM_DMACR, 32'h0000_1001, "S2MM run");

        // Enable the CNN's interrupt once. A driver does not re-enable it per
        // frame, so neither does this.
        write32(CNN_GIE, 32'h1, "CNN GIE");
        write32(CNN_IER, 32'h1, "CNN IER");

        for (int frame = 0; frame < NUM_FRAMES; frame++) begin
            $display("");
            $display("[TB] ===== frame %0d (sample_%0d) =====", frame, frame);
            frame_index = frame;

            load_input_ddr(frame);

            // Arm receive first so the CNN output is never backpressured.
            write32(S2MM_DA,     (OUTPUT_DDR + frame * OUTPUT_STRIDE),
                    "S2MM destination");
            write32(S2MM_LENGTH, S2MM_BYTES, "S2MM length");

            // Program the input transfer BEFORE starting the CNN. The wrapper
            // gates its stream input until CTRL[0] is written, so nothing may
            // reach the core yet -- this is the race a driver can lose.
            write32(MM2S_SA,     INPUT_DDR[31:0], "MM2S source");
            write32(MM2S_LENGTH, MM2S_BYTES,      "MM2S length");

            repeat (400) @(posedge aclk);
            beats_before_start = cnn_in_beats[frame];
            if (beats_before_start != 0) begin
                $error("frame %0d: CNN consumed %0d beats before CTRL[0] was written",
                       frame, beats_before_start);
                errors++;
            end
            read32(CNN_CTRL, "CNN CTRL", value);
            expect32(value, 32'h2,
                     $sformatf("frame %0d CNN CTRL before start (idle, not running)", frame));

            write32(CNN_CTRL, 32'h1, "CNN start");

            wait_for_intc(IRQ_DONE, frame);

            // Let the last AXI write retire before reading the snoop.
            repeat (20) @(posedge aclk);

            read32(INTC_ISR, "INTC ISR", ipr_snapshot);
            if ((ipr_snapshot & IRQ_ALL) !== IRQ_ALL) begin
                $error("frame %0d: INTC ISR = 0x%08h, expected all of 0x%08h (MM2S, S2MM, CNN)",
                       frame, ipr_snapshot, IRQ_ALL);
                errors++;
            end
            // Highest priority is the lowest-numbered pending interrupt.
            read32(INTC_IVR, "INTC IVR", value);
            expect32(value, IRQ_MM2S, $sformatf("frame %0d INTC IVR", frame));

            read32(MM2S_DMASR, "MM2S DMASR", value);
            if (!value[1] || value[6:4] != 3'b000) begin
                $error("frame %0d: MM2S did not finish cleanly: DMASR=0x%08h",
                       frame, value);
                errors++;
            end
            read32(S2MM_DMASR, "S2MM DMASR", value);
            if (!value[1] || value[6:4] != 3'b000) begin
                $error("frame %0d: S2MM did not finish cleanly: DMASR=0x%08h",
                       frame, value);
                errors++;
            end
            read32(CNN_STATUS, "CNN STATUS", value);
            expect32(value, 32'h3,
                     $sformatf("frame %0d CNN STATUS at completion (done and idle)", frame));

            check_frame_results(frame);
            clear_all_interrupts(frame);
        end

        $display("");
        if (errors == 0)
            $display("[TB] PASS: %0d back-to-back inferences, interrupts through axi_intc_0",
                     NUM_FRAMES);
        else
            $fatal(1, "[TB] FAIL: %0d error(s)", errors);

        $finish;
    end

    // Two frames are ~2.1 ms of simulated time; 40 ms bounds a deadlock.
    initial begin : watchdog
        #40ms;
        $display("[TB] TIMEOUT in frame %0d: cnn_in=%0d cnn_out=%0d s2mm_bytes=%0d ps_irq=%b core_state=%0d",
                 frame_index, cnn_in_beats[frame_index], cnn_out_beats[frame_index],
                 s2mm_bytes_written[frame_index], ps_irq,
                 dut.system_i.CNN_wrapper_0.inst.u_ecg_accel_top.state);
        $fatal(1, "[TB] TIMEOUT");
    end

    initial begin : progress_report
        forever begin
            #500us;
            $display("[TB] progress: t=%0t frame=%0d cnn_in=%0d cnn_out=%0d s2mm_bytes=%0d ps_irq=%b",
                     $time, frame_index, cnn_in_beats[frame_index],
                     cnn_out_beats[frame_index], s2mm_bytes_written[frame_index],
                     ps_irq);
        end
    end

    // ------------------------------------------------------------------
    // Stream snoops, attributed to the frame under test
    // ------------------------------------------------------------------
    initial begin
        for (int f = 0; f < NUM_FRAMES; f++) begin
            cnn_in_beats[f]       = 0;
            cnn_out_beats[f]      = 0;
            cnn_tlast_beat[f]     = 0;
            s2mm_bytes_written[f] = 0;
        end
        s2mm_wr_addr = '0;
    end

    always @(posedge aclk) begin
        if (dut.system_i.proc_sys_reset_2_peripheral_aresetn === 1'b1) begin
            if (dut.system_i.axis_data_fifo_0_M_AXIS_TVALID &&
                dut.system_i.axis_data_fifo_0_M_AXIS_TREADY)
                cnn_in_beats[frame_index] <= cnn_in_beats[frame_index] + 1;

            if (dut.system_i.CNN_wrapper_0_m_axis_TVALID &&
                dut.system_i.CNN_wrapper_0_m_axis_TREADY) begin
                if (cnn_out_beats[frame_index] < OUTPUT_SAMPLES)
                    cnn_logits[frame_index][cnn_out_beats[frame_index]] <=
                        dut.system_i.CNN_wrapper_0_m_axis_TDATA;
                if (dut.system_i.CNN_wrapper_0_m_axis_TLAST)
                    cnn_tlast_beat[frame_index] <= cnn_out_beats[frame_index] + 1;
                cnn_out_beats[frame_index] <= cnn_out_beats[frame_index] + 1;
            end
        end
    end

    // Rebuild the DDR image the S2MM channel writes for the current frame.
    always @(posedge aclk) begin
        int unsigned byte_index;
        if (dut.system_i.proc_sys_reset_2_peripheral_aresetn === 1'b1) begin
            if (dut.system_i.axi_dma_0_M_AXI_S2MM_AWVALID &&
                dut.system_i.axi_dma_0_M_AXI_S2MM_AWREADY)
                s2mm_wr_addr = {8'h00, dut.system_i.axi_dma_0_M_AXI_S2MM_AWADDR};

            if (dut.system_i.axi_dma_0_M_AXI_S2MM_WVALID &&
                dut.system_i.axi_dma_0_M_AXI_S2MM_WREADY) begin
                for (int b = 0; b < 4; b++) begin
                    if (dut.system_i.axi_dma_0_M_AXI_S2MM_WSTRB[b]) begin
                        // Unsigned wrap puts anything outside this frame's
                        // output page far above S2MM_BYTES, so one comparison
                        // covers both ends of the range.
                        byte_index = (s2mm_wr_addr + b)
                                     - (OUTPUT_DDR + frame_index * OUTPUT_STRIDE);
                        if (byte_index < S2MM_BYTES) begin
                            s2mm_image[frame_index][byte_index] =
                                dut.system_i.axi_dma_0_M_AXI_S2MM_WDATA[b*8 +: 8];
                            s2mm_bytes_written[frame_index] =
                                s2mm_bytes_written[frame_index] + 1;
                        end
                    end
                end
                s2mm_wr_addr = s2mm_wr_addr + 4;
            end
        end
    end

endmodule
