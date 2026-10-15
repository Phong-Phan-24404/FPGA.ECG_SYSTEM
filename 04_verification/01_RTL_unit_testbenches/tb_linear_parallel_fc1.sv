`timescale 1ns / 1ps
module tb_linear_parallel_fc1;
    tb_linear_parallel_golden #(
        .IN_FEATURES(256), .OUT_FEATURES(64), .PAR_OUT(16), .WEIGHT_ADDR_WIDTH(10),
        .WEIGHT_PATH("datasets/golden_fixed/weights_hex/fc1_weight.hex"),
        .BIAS_PATH("datasets/golden_fixed/weights_hex/fc1_bias.hex"),
        .INPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/flatten.hex"),
        .OUTPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/fc1.hex"),
        .TEST_NAME("tb_linear_parallel_fc1")
    ) i_tb ();
endmodule
