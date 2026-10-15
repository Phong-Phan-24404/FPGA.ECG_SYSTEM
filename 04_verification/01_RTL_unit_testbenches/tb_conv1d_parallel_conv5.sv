`timescale 1ns / 1ps
module tb_conv1d_parallel_conv5;
    tb_conv1d_parallel_golden #(
        .IN_CHANNELS(32), .OUT_CHANNELS(256), .KERNEL_SIZE(3), .PAR_OUT(16), .K_PAR(1),
        .WEIGHT_ADDR_WIDTH(11), .IN_LENGTH(42), .OUT_LENGTH(40),
        .WEIGHT_PATH("datasets/golden_fixed/weights_hex/conv5_weight.hex"),
        .BIAS_PATH("datasets/golden_fixed/weights_hex/conv5_bias.hex"),
        .INPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/pool2.hex"),
        .OUTPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/conv5.hex"),
        .TEST_NAME("tb_conv1d_parallel_conv5")
    ) i_tb ();
endmodule
