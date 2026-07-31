// CNN_wrapper.sv
// AXI4-Lite + AXI4-Stream wrapper for ecg_accel_top.
// Target use: Xilinx Vivado IP packaging for Kria KV260 / Zynq UltraScale+ MPSoC.
//
// Register map, 32-bit AXI4-Lite, byte address:
//   0x00 CTRL   write bit[0] = start pulse, write bit[1] = clear done/IRQ sticky
//               read  bit[0] = run_enable, bit[1] = core_idle, bit[2] = busy
//   0x04 STATUS read  bit[0] = done_sticky, bit[1] = core_idle, bit[2] = busy
//   0x08 GIE    bit[0] = global interrupt enable
//   0x0C IER    bit[0] = done interrupt enable
//   0x10 ISR    bit[0] = done interrupt status, write 1 to clear
//
// Notes:
// - s_axi_aresetn is active-low and synchronous to s_axi_aclk.
// - The wrapper uses one clock domain. AXI4-Lite, AXI-Stream, and ecg_accel_top
//   all run from s_axi_aclk/s_axi_aresetn.
// - Incoming AXI-Stream data is gated until software writes CTRL[0]=1.

`timescale 1ns / 1ps

module CNN_wrapper #(
    parameter int DATA_WIDTH         = 16,
    parameter bit REGISTERED_MATH    = 0,
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int C_S_AXI_ADDR_WIDTH = 6
)(
    // Shared clock/reset
    input  logic                              s_axi_aclk,
    input  logic                              s_axi_aresetn,

    // AXI4-Lite slave control interface
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  logic [2:0]                        s_axi_awprot,
    input  logic                              s_axi_awvalid,
    output logic                              s_axi_awready,

    input  logic [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
    input  logic [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  logic                              s_axi_wvalid,
    output logic                              s_axi_wready,

    output logic [1:0]                        s_axi_bresp,
    output logic                              s_axi_bvalid,
    input  logic                              s_axi_bready,

    input  logic [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  logic [2:0]                        s_axi_arprot,
    input  logic                              s_axi_arvalid,
    output logic                              s_axi_arready,

    output logic [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
    output logic [1:0]                        s_axi_rresp,
    output logic                              s_axi_rvalid,
    input  logic                              s_axi_rready,

    // AXI4-Stream slave input to CNN
    input  logic [DATA_WIDTH-1:0]             s_axis_tdata,
    input  logic                              s_axis_tvalid,
    output logic                              s_axis_tready,
    input  logic                              s_axis_tlast,

    // AXI4-Stream master output from CNN
    output logic [DATA_WIDTH-1:0]             m_axis_tdata,
    output logic                              m_axis_tvalid,
    input  logic                              m_axis_tready,
    output logic                              m_axis_tlast,

    // Optional interrupt to PS interrupt controller
    output logic                              interrupt
);

    // This wrapper is written for 32-bit AXI4-Lite accesses.
    initial begin
        assert (C_S_AXI_DATA_WIDTH == 32)
            else $fatal(1, "CNN_wrapper requires C_S_AXI_DATA_WIDTH == 32");
        assert (C_S_AXI_ADDR_WIDTH >= 6)
            else $fatal(1, "CNN_wrapper requires C_S_AXI_ADDR_WIDTH >= 6");
    end

    localparam logic [3:0] ADDR_CTRL   = 4'h0; // 0x00 >> 2
    localparam logic [3:0] ADDR_STATUS = 4'h1; // 0x04 >> 2
    localparam logic [3:0] ADDR_GIE    = 4'h2; // 0x08 >> 2
    localparam logic [3:0] ADDR_IER    = 4'h3; // 0x0C >> 2
    localparam logic [3:0] ADDR_ISR    = 4'h4; // 0x10 >> 2

    // AXI4-Lite write skid registers. Supports independent AW and W arrival.
    logic [C_S_AXI_ADDR_WIDTH-1:0]     awaddr_reg;
    logic                              awaddr_valid;
    logic [C_S_AXI_DATA_WIDTH-1:0]     wdata_reg;
    logic [(C_S_AXI_DATA_WIDTH/8)-1:0] wstrb_reg;
    logic                              wdata_valid;

    // Control/status registers.
    logic        start_pulse;
    logic        run_enable;
    logic        done_sticky;
    logic [31:0] gie_reg;
    logic [31:0] ier_reg;
    logic [31:0] isr_reg;

    // Core sideband/status.
    logic core_done;
    logic core_idle;
    logic busy;

    // AXI-Stream gating between wrapper and ecg_accel_top.
    logic core_s_axis_tvalid;
    logic core_s_axis_tready;

    // Gate input while the completion pulse is visible so a second frame cannot
    // slip into the core before software issues the next start.
    assign busy               = run_enable && !core_done && !core_idle;
    assign core_s_axis_tvalid = (run_enable && !core_done) ? s_axis_tvalid : 1'b0;
    assign s_axis_tready      = (run_enable && !core_done) ? core_s_axis_tready : 1'b0;

    // AXI4-Lite fixed OKAY responses.
    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // Only accept one outstanding write/read transaction.
    assign s_axi_awready = (!awaddr_valid) && (!s_axi_bvalid);
    assign s_axi_wready  = (!wdata_valid)  && (!s_axi_bvalid);
    assign s_axi_arready = (!s_axi_rvalid);

    assign interrupt = gie_reg[0] & ier_reg[0] & isr_reg[0];

    function automatic [31:0] apply_wstrb(
        input [31:0] old_value,
        input [31:0] new_value,
        input [3:0]  byte_enable
    );
        automatic logic [31:0] result;
        begin
            result = old_value;
            for (int i = 0; i < 4; i++) begin
                if (byte_enable[i]) begin
                    result[i*8 +: 8] = new_value[i*8 +: 8];
                end
            end
            return result;
        end
    endfunction

    function automatic [31:0] read_register(
        input [C_S_AXI_ADDR_WIDTH-1:0] addr
    );
        automatic logic [31:0] data;
        begin
            data = 32'h0000_0000;
            unique case (addr[5:2])
                ADDR_CTRL: begin
                    data[0] = run_enable;
                    data[1] = core_idle;
                    data[2] = busy;
                end
                ADDR_STATUS: begin
                    data[0] = done_sticky;
                    data[1] = core_idle;
                    data[2] = busy;
                end
                ADDR_GIE: data = gie_reg;
                ADDR_IER: data = ier_reg;
                ADDR_ISR: data = isr_reg;
                default:  data = 32'h0000_0000;
            endcase
            return data;
        end
    endfunction

    wire write_fire = awaddr_valid && wdata_valid && !s_axi_bvalid;

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            awaddr_reg    <= '0;
            awaddr_valid  <= 1'b0;
            wdata_reg     <= '0;
            wstrb_reg     <= '0;
            wdata_valid   <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= '0;
            start_pulse   <= 1'b0;
            run_enable    <= 1'b0;
            done_sticky   <= 1'b0;
            gie_reg       <= 32'h0000_0000;
            ier_reg       <= 32'h0000_0000;
            isr_reg       <= 32'h0000_0000;
        end else begin
            start_pulse <= 1'b0;

            // Capture AXI4-Lite write address and data independently.
            if (s_axi_awvalid && s_axi_awready) begin
                awaddr_reg   <= s_axi_awaddr;
                awaddr_valid <= 1'b1;
            end

            if (s_axi_wvalid && s_axi_wready) begin
                wdata_reg   <= s_axi_wdata;
                wstrb_reg   <= s_axi_wstrb;
                wdata_valid <= 1'b1;
            end

            // Perform register write when both AW and W have arrived.
            if (write_fire) begin
                unique case (awaddr_reg[5:2])
                    ADDR_CTRL: begin
                        // CTRL[0] is write-one-to-start pulse.
                        if (wstrb_reg[0] && wdata_reg[0]) begin
                            start_pulse <= 1'b1;
                            run_enable  <= 1'b1;
                        end

                        // CTRL[1] clears done/IRQ sticky bits.
                        if (wstrb_reg[0] && wdata_reg[1]) begin
                            done_sticky <= 1'b0;
                            isr_reg[0]  <= 1'b0;
                        end
                    end

                    ADDR_GIE: begin
                        gie_reg <= apply_wstrb(gie_reg, wdata_reg, wstrb_reg);
                    end

                    ADDR_IER: begin
                        ier_reg <= apply_wstrb(ier_reg, wdata_reg, wstrb_reg);
                    end

                    ADDR_ISR: begin
                        // ISR is write-one-to-clear.
                        if (wstrb_reg[0] && wdata_reg[0]) begin
                            isr_reg[0]  <= 1'b0;
                            done_sticky <= 1'b0;
                        end
                    end

                    default: begin
                        // Unmapped writes return OKAY and have no side effect.
                    end
                endcase

                awaddr_valid <= 1'b0;
                wdata_valid  <= 1'b0;
                s_axi_bvalid <= 1'b1;
            end

            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            // AXI4-Lite read path.
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rdata  <= read_register(s_axi_araddr);
                s_axi_rvalid <= 1'b1;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end

            // Latch core completion. Core done wins over software clear if both occur.
            if (core_done) begin
                done_sticky <= 1'b1;
                isr_reg[0]  <= 1'b1;
                run_enable  <= 1'b0;
            end
        end
    end

    ecg_accel_top #(
        .DATA_WIDTH(DATA_WIDTH),
        .REGISTERED_MATH(REGISTERED_MATH)
    ) u_ecg_accel_top (
        .aclk(s_axi_aclk),
        .aresetn(s_axi_aresetn),

        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(core_s_axis_tvalid),
        .s_axis_tready(core_s_axis_tready),
        .s_axis_tlast(s_axis_tlast),

        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),

        .ctrl_start(start_pulse),
        .ctrl_done(core_done),
        .ctrl_idle(core_idle)
    );

    // Protocol sanity checks for simulation/formal. Ignored by synthesis.
`ifndef SYNTHESIS
    property p_output_stable_when_stalled;
        @(posedge s_axi_aclk) disable iff (!s_axi_aresetn)
        m_axis_tvalid && !m_axis_tready
        |=> m_axis_tvalid && $stable({m_axis_tdata, m_axis_tlast});
    endproperty
    assert property (p_output_stable_when_stalled);

    property p_start_pulse_one_cycle;
        @(posedge s_axi_aclk) disable iff (!s_axi_aresetn)
        start_pulse |=> !start_pulse;
    endproperty
    assert property (p_start_pulse_one_cycle);
`endif

endmodule
