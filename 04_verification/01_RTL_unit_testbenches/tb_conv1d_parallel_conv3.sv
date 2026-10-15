`timescale 1ns / 1ps
module tb_conv1d_parallel_conv3;
    tb_conv1d_parallel_golden #(
        .IN_CHANNELS(16), .OUT_CHANNELS(32), .KERNEL_SIZE(3), .PAR_OUT(4), .K_PAR(1),
        .WEIGHT_ADDR_WIDTH(9), .IN_LENGTH(89), .OUT_LENGTH(87),
        .WEIGHT_PATH("datasets/golden_fixed/weights_hex/conv3_weight.hex"),
        .BIAS_PATH("datasets/golden_fixed/weights_hex/conv3_bias.hex"),
        .INPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/pool1.hex"),
        .OUTPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/conv3.hex"),
        .TEST_NAME("tb_conv1d_parallel_conv3")
    ) i_tb ();
endmodule
