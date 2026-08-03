`timescale 1ns / 1ps

import ecg_params_pkg::*;

module ecg_accel_top #(
    parameter int DATA_WIDTH = 16,
    parameter bit REGISTERED_MATH = 0
)(
    input  logic                  aclk,
    input  logic                  aresetn,

    // AXI-Stream Slave (Input)
    input  logic [DATA_WIDTH-1:0] s_axis_tdata,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,
    input  logic                  s_axis_tlast,

    // AXI-Stream Master (Output)
    output logic [DATA_WIDTH-1:0] m_axis_tdata,
    output logic                  m_axis_tvalid,
    input  logic                  m_axis_tready,
    output logic                  m_axis_tlast,

    // Sideband Control
    input  logic                  ctrl_start,
    output logic                  ctrl_done,
    output logic                  ctrl_idle
);

    // Active status FSM
    typedef enum logic {
        IDLE = 1'b0,
        BUSY = 1'b1
    } top_state_t;

    top_state_t state;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            state     <= IDLE;
            ctrl_done <= 1'b0;
        end else begin
            ctrl_done <= 1'b0;
            case (state)
                IDLE: begin
                    if (ctrl_start || (s_axis_tvalid && s_axis_tready)) begin
                        state <= BUSY;
                    end
                end
                BUSY: begin
                    if (m_axis_tvalid && m_axis_tready && m_axis_tlast) begin
                        ctrl_done <= 1'b1;
                        state     <= IDLE;
                    end
                end
                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

    assign ctrl_idle = (state == IDLE);

    // BRAM Stub declarations (Tied off to zero for dataflow test)
    logic [11:0] w_addr_conv1, w_addr_conv2, w_addr_conv3, w_addr_conv4;
    logic [14:0] w_addr_conv5;
    logic [17:0] w_addr_conv6;
    logic [7:0]  b_addr_conv1, b_addr_conv2, b_addr_conv3, b_addr_conv4, b_addr_conv5, b_addr_conv6;

    logic [13:0] w_addr_fc1, w_addr_fc2, w_addr_fc3;
    logic [7:0]  b_addr_fc1, b_addr_fc2, b_addr_fc3;

    // ROM Output data signals
    logic [WEIGHT_WIDTH-1:0] w_data_conv1, w_data_conv2, w_data_conv3, w_data_conv4;
    logic [WEIGHT_WIDTH-1:0] w_data_conv5;
    logic [WEIGHT_WIDTH-1:0] w_data_conv6;
    logic [WEIGHT_WIDTH-1:0] b_data_conv1, b_data_conv2, b_data_conv3, b_data_conv4, b_data_conv5, b_data_conv6;

    logic [WEIGHT_WIDTH-1:0] w_data_fc1, w_data_fc2, w_data_fc3;
    logic [WEIGHT_WIDTH-1:0] b_data_fc1, b_data_fc2, b_data_fc3;

    generate
        if (REGISTERED_MATH) begin : gen_roms
            ecg_rom #(WEIGHT_WIDTH, 80, "datasets/golden_fixed/weights_hex/conv1_weight.hex") rom_w_conv1 (aclk, w_addr_conv1[$clog2(80)-1:0], w_data_conv1);
            ecg_rom #(WEIGHT_WIDTH, 16, "datasets/golden_fixed/weights_hex/conv1_bias.hex") rom_b_conv1 (aclk, b_addr_conv1[$clog2(16)-1:0], b_data_conv1);

            ecg_rom #(WEIGHT_WIDTH, 1280, "datasets/golden_fixed/weights_hex/conv2_weight.hex") rom_w_conv2 (aclk, w_addr_conv2[$clog2(1280)-1:0], w_data_conv2);
            ecg_rom #(WEIGHT_WIDTH, 16, "datasets/golden_fixed/weights_hex/conv2_bias.hex") rom_b_conv2 (aclk, b_addr_conv2[$clog2(16)-1:0], b_data_conv2);

            ecg_rom #(WEIGHT_WIDTH, 1536, "datasets/golden_fixed/weights_hex/conv3_weight.hex") rom_w_conv3 (aclk, w_addr_conv3[$clog2(1536)-1:0], w_data_conv3);
            ecg_rom #(WEIGHT_WIDTH, 32, "datasets/golden_fixed/weights_hex/conv3_bias.hex") rom_b_conv3 (aclk, b_addr_conv3[$clog2(32)-1:0], b_data_conv3);

            ecg_rom #(WEIGHT_WIDTH, 3072, "datasets/golden_fixed/weights_hex/conv4_weight.hex") rom_w_conv4 (aclk, w_addr_conv4, w_data_conv4);
            ecg_rom #(WEIGHT_WIDTH, 32, "datasets/golden_fixed/weights_hex/conv4_bias.hex") rom_b_conv4 (aclk, b_addr_conv4[$clog2(32)-1:0], b_data_conv4);

            ecg_rom #(WEIGHT_WIDTH, 24576, "datasets/golden_fixed/weights_hex/conv5_weight.hex") rom_w_conv5 (aclk, w_addr_conv5, w_data_conv5);
            ecg_rom #(WEIGHT_WIDTH, 256, "datasets/golden_fixed/weights_hex/conv5_bias.hex") rom_b_conv5 (aclk, b_addr_conv5, b_data_conv5);

            ecg_rom #(WEIGHT_WIDTH, 196608, "datasets/golden_fixed/weights_hex/conv6_weight.hex") rom_w_conv6 (aclk, w_addr_conv6, w_data_conv6);
            ecg_rom #(WEIGHT_WIDTH, 256, "datasets/golden_fixed/weights_hex/conv6_bias.hex") rom_b_conv6 (aclk, b_addr_conv6, b_data_conv6);

            ecg_rom #(WEIGHT_WIDTH, 16384, "datasets/golden_fixed/weights_hex/fc1_weight.hex") rom_w_fc1 (aclk, w_addr_fc1, w_data_fc1);
            ecg_rom #(WEIGHT_WIDTH, 64, "datasets/golden_fixed/weights_hex/fc1_bias.hex") rom_b_fc1 (aclk, b_addr_fc1[$clog2(64)-1:0], b_data_fc1);

            ecg_rom #(WEIGHT_WIDTH, 4096, "datasets/golden_fixed/weights_hex/fc2_weight.hex") rom_w_fc2 (aclk, w_addr_fc2[$clog2(4096)-1:0], w_data_fc2);
            ecg_rom #(WEIGHT_WIDTH, 64, "datasets/golden_fixed/weights_hex/fc2_bias.hex") rom_b_fc2 (aclk, b_addr_fc2[$clog2(64)-1:0], b_data_fc2);

            ecg_rom #(WEIGHT_WIDTH, 320, "datasets/golden_fixed/weights_hex/fc3_weight.hex") rom_w_fc3 (aclk, w_addr_fc3[$clog2(320)-1:0], w_data_fc3);
            ecg_rom #(WEIGHT_WIDTH, 5, "datasets/golden_fixed/weights_hex/fc3_bias.hex") rom_b_fc3 (aclk, b_addr_fc3[$clog2(5)-1:0], b_data_fc3);
        end else begin : gen_stub_roms
            assign w_data_conv1 = '0; assign b_data_conv1 = '0;
            assign w_data_conv2 = '0; assign b_data_conv2 = '0;
            assign w_data_conv3 = '0; assign b_data_conv3 = '0;
            assign w_data_conv4 = '0; assign b_data_conv4 = '0;
            assign w_data_conv5 = '0; assign b_data_conv5 = '0;
            assign w_data_conv6 = '0; assign b_data_conv6 = '0;
            assign w_data_fc1   = '0; assign b_data_fc1   = '0;
            assign w_data_fc2   = '0; assign b_data_fc2   = '0;
            assign w_data_fc3   = '0; assign b_data_fc3   = '0;
        end
    endgenerate

    // Chaining signals between streaming layers
    // Format: layerN_tdata, layerN_tvalid, layerN_tready, layerN_tlast

    // conv1
    logic [DATA_WIDTH-1:0] c1_tdata;
    logic                  c1_tvalid;
    logic                  c1_tready;
    logic                  c1_tlast;

    // relu1
    logic [DATA_WIDTH-1:0] r1_tdata;
    logic                  r1_tvalid;
    logic                  r1_tready;
    logic                  r1_tlast;

    // conv2
    logic [DATA_WIDTH-1:0] c2_tdata;
    logic                  c2_tvalid;
    logic                  c2_tready;
    logic                  c2_tlast;

    // relu2
    logic [DATA_WIDTH-1:0] r2_tdata;
    logic                  r2_tvalid;
    logic                  r2_tready;
    logic                  r2_tlast;

    // pool1
    logic [DATA_WIDTH-1:0] p1_tdata;
    logic                  p1_tvalid;
    logic                  p1_tready;
    logic                  p1_tlast;

    // conv3
    logic [DATA_WIDTH-1:0] c3_tdata;
    logic                  c3_tvalid;
    logic                  c3_tready;
    logic                  c3_tlast;

    // relu3
    logic [DATA_WIDTH-1:0] r3_tdata;
    logic                  r3_tvalid;
    logic                  r3_tready;
    logic                  r3_tlast;

    // conv4
    logic [DATA_WIDTH-1:0] c4_tdata;
    logic                  c4_tvalid;
    logic                  c4_tready;
    logic                  c4_tlast;

    // relu4
    logic [DATA_WIDTH-1:0] r4_tdata;
    logic                  r4_tvalid;
    logic                  r4_tready;
    logic                  r4_tlast;

    // pool2
    logic [DATA_WIDTH-1:0] p2_tdata;
    logic                  p2_tvalid;
    logic                  p2_tready;
    logic                  p2_tlast;

    // conv5
    logic [DATA_WIDTH-1:0] c5_tdata;
    logic                  c5_tvalid;
    logic                  c5_tready;
    logic                  c5_tlast;

    // relu5
    logic [DATA_WIDTH-1:0] r5_tdata;
    logic                  r5_tvalid;
    logic                  r5_tready;
    logic                  r5_tlast;

    // conv6
    logic [DATA_WIDTH-1:0] c6_tdata;
    logic                  c6_tvalid;
    logic                  c6_tready;
    logic                  c6_tlast;

    // relu6
    logic [DATA_WIDTH-1:0] r6_tdata;
    logic                  r6_tvalid;
    logic                  r6_tready;
    logic                  r6_tlast;

    // gpool
    logic [DATA_WIDTH-1:0] gp_tdata;
    logic                  gp_tvalid;
    logic                  gp_tready;
    logic                  gp_tlast;

    // fc1
    logic [DATA_WIDTH-1:0] f1_tdata;
    logic                  f1_tvalid;
    logic                  f1_tready;
    logic                  f1_tlast;

    // relu7
    logic [DATA_WIDTH-1:0] r7_tdata;
    logic                  r7_tvalid;
    logic                  r7_tready;
    logic                  r7_tlast;

    // fc2
    logic [DATA_WIDTH-1:0] f2_tdata;
    logic                  f2_tvalid;
    logic                  f2_tready;
    logic                  f2_tlast;

    // relu8
    logic [DATA_WIDTH-1:0] r8_tdata;
    logic                  r8_tvalid;
    logic                  r8_tready;
    logic                  r8_tlast;

    // Instance 1: conv1d_stream (conv1)
    conv1d_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .IN_CHANNELS(CONV1_IN_CH),
        .OUT_CHANNELS(CONV1_OUT_CH),
        .KERNEL_SIZE(CONV1_K),
        .STRIDE(CONV1_S),
        .REGISTERED_MATH(REGISTERED_MATH),
        .WEIGHT_ADDR_WIDTH(12)
    ) i_conv1 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(c1_tdata),
        .m_axis_tvalid(c1_tvalid),
        .m_axis_tready(c1_tready),
        .m_axis_tlast(c1_tlast),
        .weight_addr(w_addr_conv1),
        .weight_data(w_data_conv1),
        .bias_addr(b_addr_conv1),
        .bias_data(b_data_conv1)
    );

    // Instance 2: relu_stream (relu1)
    relu_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .REGISTERED(1)
    ) i_relu1 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(c1_tdata),
        .s_axis_tvalid(c1_tvalid),
        .s_axis_tready(c1_tready),
        .s_axis_tlast(c1_tlast),
        .m_axis_tdata(r1_tdata),
        .m_axis_tvalid(r1_tvalid),
        .m_axis_tready(r1_tready),
        .m_axis_tlast(r1_tlast)
    );

    // Instance 3: conv1d_stream (conv2)
    conv1d_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .IN_CHANNELS(CONV2_IN_CH),
        .OUT_CHANNELS(CONV2_OUT_CH),
        .KERNEL_SIZE(CONV2_K),
        .STRIDE(CONV2_S),
        .REGISTERED_MATH(REGISTERED_MATH),
        .WEIGHT_ADDR_WIDTH(12)
    ) i_conv2 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(r1_tdata),
        .s_axis_tvalid(r1_tvalid),
        .s_axis_tready(r1_tready),
        .s_axis_tlast(r1_tlast),
        .m_axis_tdata(c2_tdata),
        .m_axis_tvalid(c2_tvalid),
        .m_axis_tready(c2_tready),
        .m_axis_tlast(c2_tlast),
        .weight_addr(w_addr_conv2),
        .weight_data(w_data_conv2),
        .bias_addr(b_addr_conv2),
        .bias_data(b_data_conv2)
    );

    // Instance 4: relu_stream (relu2)
    relu_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .REGISTERED(1)
    ) i_relu2 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(c2_tdata),
        .s_axis_tvalid(c2_tvalid),
        .s_axis_tready(c2_tready),
        .s_axis_tlast(c2_tlast),
        .m_axis_tdata(r2_tdata),
        .m_axis_tvalid(r2_tvalid),
        .m_axis_tready(r2_tready),
        .m_axis_tlast(r2_tlast)
    );

    // Instance 5: maxpool1d_stream (pool1)
    maxpool1d_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .CHANNELS(POOL1_CH),
        .KERNEL_SIZE(POOL1_K),
        .STRIDE(POOL1_S),
        .IN_STEPS(POOL1_IN_STEPS)
    ) i_pool1 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(r2_tdata),
        .s_axis_tvalid(r2_tvalid),
        .s_axis_tready(r2_tready),
        .s_axis_tlast(r2_tlast),
        .m_axis_tdata(p1_tdata),
        .m_axis_tvalid(p1_tvalid),
        .m_axis_tready(p1_tready),
        .m_axis_tlast(p1_tlast)
    );

    // Instance 6: conv1d_stream (conv3)
    conv1d_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .IN_CHANNELS(CONV3_IN_CH),
        .OUT_CHANNELS(CONV3_OUT_CH),
        .KERNEL_SIZE(CONV3_K),
        .STRIDE(CONV3_S),
        .REGISTERED_MATH(REGISTERED_MATH),
        .WEIGHT_ADDR_WIDTH(12)
    ) i_conv3 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(p1_tdata),
        .s_axis_tvalid(p1_tvalid),
        .s_axis_tready(p1_tready),
        .s_axis_tlast(p1_tlast),
        .m_axis_tdata(c3_tdata),
        .m_axis_tvalid(c3_tvalid),
        .m_axis_tready(c3_tready),
        .m_axis_tlast(c3_tlast),
        .weight_addr(w_addr_conv3),
        .weight_data(w_data_conv3),
        .bias_addr(b_addr_conv3),
        .bias_data(b_data_conv3)
    );

    // Instance 7: relu_stream (relu3)
    relu_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .REGISTERED(1)
    ) i_relu3 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(c3_tdata),
        .s_axis_tvalid(c3_tvalid),
        .s_axis_tready(c3_tready),
        .s_axis_tlast(c3_tlast),
        .m_axis_tdata(r3_tdata),
        .m_axis_tvalid(r3_tvalid),
        .m_axis_tready(r3_tready),
        .m_axis_tlast(r3_tlast)
    );

    // Instance 8: conv1d_stream (conv4)
    conv1d_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .IN_CHANNELS(CONV4_IN_CH),
        .OUT_CHANNELS(CONV4_OUT_CH),
        .KERNEL_SIZE(CONV4_K),
        .STRIDE(CONV4_S),
        .REGISTERED_MATH(REGISTERED_MATH),
        .WEIGHT_ADDR_WIDTH(12)
    ) i_conv4 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(r3_tdata),
        .s_axis_tvalid(r3_tvalid),
        .s_axis_tready(r3_tready),
        .s_axis_tlast(r3_tlast),
        .m_axis_tdata(c4_tdata),
        .m_axis_tvalid(c4_tvalid),
        .m_axis_tready(c4_tready),
        .m_axis_tlast(c4_tlast),
        .weight_addr(w_addr_conv4),
        .weight_data(w_data_conv4),
        .bias_addr(b_addr_conv4),
        .bias_data(b_data_conv4)
    );

    // Instance 9: relu_stream (relu4)
    relu_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .REGISTERED(1)
    ) i_relu4 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(c4_tdata),
        .s_axis_tvalid(c4_tvalid),
        .s_axis_tready(c4_tready),
        .s_axis_tlast(c4_tlast),
        .m_axis_tdata(r4_tdata),
        .m_axis_tvalid(r4_tvalid),
        .m_axis_tready(r4_tready),
        .m_axis_tlast(r4_tlast)
    );

    // Instance 10: maxpool1d_stream (pool2)
    maxpool1d_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .CHANNELS(POOL2_CH),
        .KERNEL_SIZE(POOL2_K),
        .STRIDE(POOL2_S),
        .IN_STEPS(POOL2_IN_STEPS)
    ) i_pool2 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(r4_tdata),
        .s_axis_tvalid(r4_tvalid),
        .s_axis_tready(r4_tready),
        .s_axis_tlast(r4_tlast),
        .m_axis_tdata(p2_tdata),
        .m_axis_tvalid(p2_tvalid),
        .m_axis_tready(p2_tready),
        .m_axis_tlast(p2_tlast)
    );

    // Instance 11: conv1d_stream (conv5)
    conv1d_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .IN_CHANNELS(CONV5_IN_CH),
        .OUT_CHANNELS(CONV5_OUT_CH),
        .KERNEL_SIZE(CONV5_K),
        .STRIDE(CONV5_S),
        .REGISTERED_MATH(REGISTERED_MATH),
        .WEIGHT_ADDR_WIDTH(15)
    ) i_conv5 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(p2_tdata),
        .s_axis_tvalid(p2_tvalid),
        .s_axis_tready(p2_tready),
        .s_axis_tlast(p2_tlast),
        .m_axis_tdata(c5_tdata),
        .m_axis_tvalid(c5_tvalid),
        .m_axis_tready(c5_tready),
        .m_axis_tlast(c5_tlast),
        .weight_addr(w_addr_conv5),
        .weight_data(w_data_conv5),
        .bias_addr(b_addr_conv5),
        .bias_data(b_data_conv5)
    );

    // Instance 12: relu_stream (relu5)
    relu_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .REGISTERED(1)
    ) i_relu5 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(c5_tdata),
        .s_axis_tvalid(c5_tvalid),
        .s_axis_tready(c5_tready),
        .s_axis_tlast(c5_tlast),
        .m_axis_tdata(r5_tdata),
        .m_axis_tvalid(r5_tvalid),
        .m_axis_tready(r5_tready),
        .m_axis_tlast(r5_tlast)
    );

    // Instance 13: conv1d_stream (conv6)
    conv1d_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .IN_CHANNELS(CONV6_IN_CH),
        .OUT_CHANNELS(CONV6_OUT_CH),
        .KERNEL_SIZE(CONV6_K),
        .STRIDE(CONV6_S),
        .REGISTERED_MATH(REGISTERED_MATH),
        .WEIGHT_ADDR_WIDTH(18)
    ) i_conv6 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(r5_tdata),
        .s_axis_tvalid(r5_tvalid),
        .s_axis_tready(r5_tready),
        .s_axis_tlast(r5_tlast),
        .m_axis_tdata(c6_tdata),
        .m_axis_tvalid(c6_tvalid),
        .m_axis_tready(c6_tready),
        .m_axis_tlast(c6_tlast),
        .weight_addr(w_addr_conv6),
        .weight_data(w_data_conv6),
        .bias_addr(b_addr_conv6),
        .bias_data(b_data_conv6)
    );

    // Instance 14: relu_stream (relu6)
    relu_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .REGISTERED(1)
    ) i_relu6 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(c6_tdata),
        .s_axis_tvalid(c6_tvalid),
        .s_axis_tready(c6_tready),
        .s_axis_tlast(c6_tlast),
        .m_axis_tdata(r6_tdata),
        .m_axis_tvalid(r6_tvalid),
        .m_axis_tready(r6_tready),
        .m_axis_tlast(r6_tlast)
    );

    // Instance 15: global_maxpool1d_stream (gpool)
    global_maxpool1d_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .CHANNELS(GPOOL_CH),
        .STEPS(GPOOL_STEPS)
    ) i_gpool (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(r6_tdata),
        .s_axis_tvalid(r6_tvalid),
        .s_axis_tready(r6_tready),
        .s_axis_tlast(r6_tlast),
        .m_axis_tdata(gp_tdata),
        .m_axis_tvalid(gp_tvalid),
        .m_axis_tready(gp_tready),
        .m_axis_tlast(gp_tlast)
    );

    // Instance 16: linear_layer_stream (fc1)
    linear_layer_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .IN_FEATURES(FC1_IN),
        .OUT_FEATURES(FC1_OUT)
    ) i_fc1 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(gp_tdata),
        .s_axis_tvalid(gp_tvalid),
        .s_axis_tready(gp_tready),
        .s_axis_tlast(gp_tlast),
        .m_axis_tdata(f1_tdata),
        .m_axis_tvalid(f1_tvalid),
        .m_axis_tready(f1_tready),
        .m_axis_tlast(f1_tlast),
        .weight_addr(w_addr_fc1),
        .weight_data(w_data_fc1),
        .bias_addr(b_addr_fc1),
        .bias_data(b_data_fc1)
    );

    // Instance 17: relu_stream (relu7)
    relu_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .REGISTERED(1)
    ) i_relu7 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(f1_tdata),
        .s_axis_tvalid(f1_tvalid),
        .s_axis_tready(f1_tready),
        .s_axis_tlast(f1_tlast),
        .m_axis_tdata(r7_tdata),
        .m_axis_tvalid(r7_tvalid),
        .m_axis_tready(r7_tready),
        .m_axis_tlast(r7_tlast)
    );

    // Instance 18: linear_layer_stream (fc2)
    linear_layer_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .IN_FEATURES(FC2_IN),
        .OUT_FEATURES(FC2_OUT)
    ) i_fc2 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(r7_tdata),
        .s_axis_tvalid(r7_tvalid),
        .s_axis_tready(r7_tready),
        .s_axis_tlast(r7_tlast),
        .m_axis_tdata(f2_tdata),
        .m_axis_tvalid(f2_tvalid),
        .m_axis_tready(f2_tready),
        .m_axis_tlast(f2_tlast),
        .weight_addr(w_addr_fc2),
        .weight_data(w_data_fc2),
        .bias_addr(b_addr_fc2),
        .bias_data(b_data_fc2)
    );

    // Instance 19: relu_stream (relu8)
    relu_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .REGISTERED(1)
    ) i_relu8 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(f2_tdata),
        .s_axis_tvalid(f2_tvalid),
        .s_axis_tready(f2_tready),
        .s_axis_tlast(f2_tlast),
        .m_axis_tdata(r8_tdata),
        .m_axis_tvalid(r8_tvalid),
        .m_axis_tready(r8_tready),
        .m_axis_tlast(r8_tlast)
    );

    // Instance 20: linear_layer_stream (fc3)
    linear_layer_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .IN_FEATURES(FC3_IN),
        .OUT_FEATURES(FC3_OUT)
    ) i_fc3 (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(r8_tdata),
        .s_axis_tvalid(r8_tvalid),
        .s_axis_tready(r8_tready),
        .s_axis_tlast(r8_tlast),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),
        .weight_addr(w_addr_fc3),
        .weight_data(w_data_fc3),
        .bias_addr(b_addr_fc3),
        .bias_data(b_data_fc3)
    );

    // Elaboration-Time Parameter Consistency Checks
    initial begin
        // Stage 1 -> 2: conv1 -> relu1
        assert (CONV1_OUT_STEPS * CONV1_OUT_CH == 2928) else $fatal(1, "[SHAPE_CHECK_FAIL] conv1 output beats mismatch! Expected 2928");

        // Stage 2 -> 3: relu1 -> conv2
        assert (CONV2_IN_STEPS == CONV1_OUT_STEPS) else $fatal(1, "[SHAPE_CHECK_FAIL] conv2 IN_STEPS != conv1 OUT_STEPS");
        assert (CONV2_IN_CH == CONV1_OUT_CH) else $fatal(1, "[SHAPE_CHECK_FAIL] conv2 IN_CH != conv1 OUT_CH");

        // Stage 3 -> 4: conv2 -> relu2
        assert (CONV2_OUT_STEPS * CONV2_OUT_CH == 2864) else $fatal(1, "[SHAPE_CHECK_FAIL] conv2 output beats mismatch! Expected 2864");

        // Stage 4 -> 5: relu2 -> pool1
        assert (POOL1_IN_STEPS == CONV2_OUT_STEPS) else $fatal(1, "[SHAPE_CHECK_FAIL] pool1 IN_STEPS != conv2 OUT_STEPS");
        assert (POOL1_CH == CONV2_OUT_CH) else $fatal(1, "[SHAPE_CHECK_FAIL] pool1 CH != conv2 OUT_CH");

        // Stage 5 -> 6: pool1 -> conv3
        assert (POOL1_OUT_STEPS * POOL1_CH == 1424) else $fatal(1, "[SHAPE_CHECK_FAIL] pool1 output beats mismatch! Expected 1424");
        assert (CONV3_IN_STEPS == POOL1_OUT_STEPS) else $fatal(1, "[SHAPE_CHECK_FAIL] conv3 IN_STEPS != pool1 OUT_STEPS");
        assert (CONV3_IN_CH == POOL1_CH) else $fatal(1, "[SHAPE_CHECK_FAIL] conv3 IN_CH != pool1 CH");

        // Stage 6 -> 7: conv3 -> relu3
        assert (CONV3_OUT_STEPS * CONV3_OUT_CH == 2784) else $fatal(1, "[SHAPE_CHECK_FAIL] conv3 output beats mismatch! Expected 2784");

        // Stage 7 -> 8: relu3 -> conv4
        assert (CONV4_IN_STEPS == CONV3_OUT_STEPS) else $fatal(1, "[SHAPE_CHECK_FAIL] conv4 IN_STEPS != conv3 OUT_STEPS");
        assert (CONV4_IN_CH == CONV3_OUT_CH) else $fatal(1, "[SHAPE_CHECK_FAIL] conv4 IN_CH != conv3 OUT_CH");

        // Stage 8 -> 9: conv4 -> relu4
        assert (CONV4_OUT_STEPS * CONV4_OUT_CH == 2720) else $fatal(1, "[SHAPE_CHECK_FAIL] conv4 output beats mismatch! Expected 2720");

        // Stage 9 -> 10: relu4 -> pool2
        assert (POOL2_IN_STEPS == CONV4_OUT_STEPS) else $fatal(1, "[SHAPE_CHECK_FAIL] pool2 IN_STEPS != conv4 OUT_STEPS");
        assert (POOL2_CH == CONV4_OUT_CH) else $fatal(1, "[SHAPE_CHECK_FAIL] pool2 CH != conv4 OUT_CH");

        // Stage 10 -> 11: pool2 -> conv5
        assert (POOL2_OUT_STEPS * POOL2_CH == 1344) else $fatal(1, "[SHAPE_CHECK_FAIL] pool2 output beats mismatch! Expected 1344");
        assert (CONV5_IN_STEPS == POOL2_OUT_STEPS) else $fatal(1, "[SHAPE_CHECK_FAIL] conv5 IN_STEPS != pool2 OUT_STEPS");
        assert (CONV5_IN_CH == POOL2_CH) else $fatal(1, "[SHAPE_CHECK_FAIL] conv5 IN_CH != pool2 CH");

        // Stage 11 -> 12: conv5 -> relu5
        assert (CONV5_OUT_STEPS * CONV5_OUT_CH == 10240) else $fatal(1, "[SHAPE_CHECK_FAIL] conv5 output beats mismatch! Expected 10240");

        // Stage 12 -> 13: relu5 -> conv6
        assert (CONV6_IN_STEPS == CONV5_OUT_STEPS) else $fatal(1, "[SHAPE_CHECK_FAIL] conv6 IN_STEPS != conv5 OUT_STEPS");
        assert (CONV6_IN_CH == CONV5_OUT_CH) else $fatal(1, "[SHAPE_CHECK_FAIL] conv6 IN_CH != conv5 OUT_CH");

        // Stage 13 -> 14: conv6 -> relu6
        assert (CONV6_OUT_STEPS * CONV6_OUT_CH == 9728) else $fatal(1, "[SHAPE_CHECK_FAIL] conv6 output beats mismatch! Expected 9728");

        // Stage 14 -> 15: relu6 -> gpool
        assert (GPOOL_STEPS == CONV6_OUT_STEPS) else $fatal(1, "[SHAPE_CHECK_FAIL] gpool STEPS != conv6 OUT_STEPS");
        assert (GPOOL_CH == CONV6_OUT_CH) else $fatal(1, "[SHAPE_CHECK_FAIL] gpool CH != conv6 OUT_CH");

        // Stage 15 -> 16: gpool -> fc1
        assert (FC1_IN == GPOOL_CH) else $fatal(1, "[SHAPE_CHECK_FAIL] fc1 IN_FEATURES != gpool CH");

        // Stage 17 -> 18: relu7 -> fc2
        assert (FC2_IN == FC1_OUT) else $fatal(1, "[SHAPE_CHECK_FAIL] fc2 IN_FEATURES != fc1 OUT_FEATURES");

        // Stage 19 -> 20: relu8 -> fc3
        assert (FC3_IN == FC2_OUT) else $fatal(1, "[SHAPE_CHECK_FAIL] fc3 IN_FEATURES != fc2 OUT_FEATURES");
    end

endmodule

module ecg_rom #(
    parameter int WIDTH = 16,
    parameter int SIZE = 256,
    parameter FILE = ""
)(
    input  logic                   clk,
    input  logic [$clog2(SIZE)-1:0] addr,
    output logic [WIDTH-1:0]       data
);
    logic [WIDTH-1:0] mem [0:SIZE-1];
    initial begin
        if (FILE != "") begin
            $readmemh(FILE, mem);
        end
    end
    always_ff @(posedge clk) begin
        data <= mem[addr];
    end
endmodule
