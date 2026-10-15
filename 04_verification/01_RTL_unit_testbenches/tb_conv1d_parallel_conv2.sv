`timescale 1ns / 1ps
module tb_conv1d_parallel_conv2;
    tb_conv1d_parallel_golden #(
        .IN_CHANNELS(16), .OUT_CHANNELS(16), .KERNEL_SIZE(5), .PAR_OUT(4), .K_PAR(1),
        .WEIGHT_ADDR_WIDTH(9), .IN_LENGTH(183), .OUT_LENGTH(179),
        .WEIGHT_PATH("datasets/golden_fixed/weights_hex/conv2_weight.hex"),
        .BIAS_PATH("datasets/golden_fixed/weights_hex/conv2_bias.hex"),
        .INPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/relu1.hex"),
        .OUTPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/conv2.hex"),
        .TEST_NAME("tb_conv1d_parallel_conv2")
    ) i_tb ();
endmodule
