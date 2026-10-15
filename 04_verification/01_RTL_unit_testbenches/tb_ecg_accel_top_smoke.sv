// d:\fpga_cc\FPGA_CNN\rtl\tb\tb_ecg_accel_top_smoke.sv
// Self-checking smoke testbench for the top-level ecg_accel_top wrapper.
// Feeds 187 beats and validates that 5 output beats are successfully produced.

`timescale 1ns / 1ps

import ecg_params_pkg::*;

module tb_ecg_accel_top_smoke;

    localparam int DATA_WIDTH = 16;

    logic                  aclk;
    logic                  aresetn;

    logic [DATA_WIDTH-1:0] s_axis_tdata;
    logic                  s_axis_tvalid;
    logic                  s_axis_tready;
    logic                  s_axis_tlast;

    logic [DATA_WIDTH-1:0] m_axis_tdata;
    logic                  m_axis_tvalid;
    logic                  m_axis_tready;
    logic                  m_axis_tlast;

    logic                  ctrl_start;
    logic                  ctrl_done;
    logic                  ctrl_idle;

    // Instantiate DUT
    ecg_accel_top #(
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),
        .ctrl_start(ctrl_start),
        .ctrl_done(ctrl_done),
        .ctrl_idle(ctrl_idle)
    );

    // Clock driver
    always #5 aclk = ~aclk;

    // Output transaction count
    int out_beat_cnt = 0;

    // Monitor output
    initial begin
        m_axis_tready = 1;
        out_beat_cnt = 0;
        
        @(posedge aresetn);
        
        // Wait for output transactions
        forever begin
            @(posedge aclk);
            if (m_axis_tvalid && m_axis_tready) begin
                $display("[MON] Output beat %d received: 0x%04H, tlast=%b", out_beat_cnt, m_axis_tdata, m_axis_tlast);
                
                // Verify tlast boundary on final beat
                if (out_beat_cnt == FC3_OUT - 1) begin
                    if (!m_axis_tlast) begin
                        $display("[FAIL] Expected tlast on output beat %d", out_beat_cnt);
                        $finish;
                    end
                end else begin
                    if (m_axis_tlast) begin
                        $display("[FAIL] Unexpected tlast on output beat %d", out_beat_cnt);
                        $finish;
                    end
                end
                
                out_beat_cnt = out_beat_cnt + 1;
                
                if (out_beat_cnt == FC3_OUT) begin
                    $display("[PASS] Received exactly %d output beats.", out_beat_cnt);
                    // Wait for FSM registers to update after the posedge
                    #1;
                    if (ctrl_done && ctrl_idle) begin
                        $display("[PASS] Control signals ctrl_done and ctrl_idle are correctly asserted.");
                        $display("==================================================");
                        $display("tb_ecg_accel_top_smoke completed! [SUCCESS]");
                        $display("==================================================");
                        $finish;
                    end else begin
                        $display("[FAIL] Control signals invalid. ctrl_done=%b, ctrl_idle=%b", ctrl_done, ctrl_idle);
                        $finish;
                    end
                end
            end
        end
    end

    // Timeout watchdog
    initial begin
        #500000; // 500us timeout
        $display("[FAIL] Simulation timeout! Output count: %d", out_beat_cnt);
        $finish;
    end

    // Stimulus driver
    initial begin
        aclk = 0;
        aresetn = 0;
        s_axis_tdata = 0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        ctrl_start = 0;

        #20;
        aresetn = 1;
        #10;

        $display("==================================================");
        $display("Running tb_ecg_accel_top_smoke...");
        $display("==================================================");

        // Pulse ctrl_start
        @(posedge aclk);
        ctrl_start = 1;
        @(posedge aclk);
        ctrl_start = 0;

        // Feed 187 input beats (CONV1_IN_STEPS * CONV1_IN_CH = 187)
        for (int i = 0; i < CONV1_IN_STEPS; i = i + 1) begin
            @(posedge aclk);
            s_axis_tdata  = 16'(i + 1); // Simple sequential ramp data
            s_axis_tvalid = 1;
            s_axis_tlast  = (i == CONV1_IN_STEPS - 1);
            while (!s_axis_tready) @(posedge aclk);
        end

        @(posedge aclk);
        s_axis_tvalid = 0;
        s_axis_tlast  = 0;
        $display("[DRV] Finished driving 187 input beats. Waiting for output...");
    end

endmodule
