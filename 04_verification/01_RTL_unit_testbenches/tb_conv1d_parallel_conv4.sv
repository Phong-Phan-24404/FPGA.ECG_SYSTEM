`timescale 1ns / 1ps
module tb_conv1d_parallel_conv4;
    tb_conv1d_parallel_golden #(
        .IN_CHANNELS(32), .OUT_CHANNELS(32), .KERNEL_SIZE(3), .PAR_OUT(8), .K_PAR(1),
        .WEIGHT_ADDR_WIDTH(9), .IN_LENGTH(87), .OUT_LENGTH(85),
        .WEIGHT_PATH("datasets/golden_fixed/weights_hex/conv4_weight.hex"),
        .BIAS_PATH("datasets/golden_fixed/weights_hex/conv4_bias.hex"),
        .INPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/relu3.hex"),
        .OUTPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/conv4.hex"),
        .TEST_NAME("tb_conv1d_parallel_conv4")
    ) i_tb ();
endmodule
