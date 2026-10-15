`timescale 1ns / 1ps
module tb_conv1d_parallel_conv6;
    tb_conv1d_parallel_golden #(
        .IN_CHANNELS(256), .OUT_CHANNELS(256), .KERNEL_SIZE(3), .PAR_OUT(32), .K_PAR(3),
        .WEIGHT_ADDR_WIDTH(11), .IN_LENGTH(40), .OUT_LENGTH(38),
        .WEIGHT_PATH("datasets/golden_fixed/weights_hex/conv6_weight.hex"),
        .BIAS_PATH("datasets/golden_fixed/weights_hex/conv6_bias.hex"),
        .INPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/relu5.hex"),
        .OUTPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/conv6.hex"),
        .TEST_NAME("tb_conv1d_parallel_conv6"),
        .MAX_FRAME_CYCLES(1000000)
    ) i_tb ();
endmodule
