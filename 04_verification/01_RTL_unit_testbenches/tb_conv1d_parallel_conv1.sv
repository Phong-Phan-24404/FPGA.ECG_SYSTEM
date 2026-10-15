`timescale 1ns / 1ps
module tb_conv1d_parallel_conv1;
    tb_conv1d_parallel_golden #(
        .IN_CHANNELS(1), .OUT_CHANNELS(16), .KERNEL_SIZE(5), .PAR_OUT(16), .K_PAR(1),
        .WEIGHT_ADDR_WIDTH(3), .IN_LENGTH(187), .OUT_LENGTH(183),
        .WEIGHT_PATH("datasets/golden_fixed/weights_hex/conv1_weight.hex"),
        .BIAS_PATH("datasets/golden_fixed/weights_hex/conv1_bias.hex"),
        .INPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/input.hex"),
        .OUTPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/conv1.hex"),
        .TEST_NAME("tb_conv1d_parallel_conv1")
    ) i_tb ();
endmodule
