`timescale 1ns / 1ps
module tb_linear_parallel_fc2;
    tb_linear_parallel_golden #(
        .IN_FEATURES(64), .OUT_FEATURES(64), .PAR_OUT(8), .WEIGHT_ADDR_WIDTH(9),
        .WEIGHT_PATH("datasets/golden_fixed/weights_hex/fc2_weight.hex"),
        .BIAS_PATH("datasets/golden_fixed/weights_hex/fc2_bias.hex"),
        .INPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/relu7.hex"),
        .OUTPUT_PATH("datasets/golden_fixed/test_vectors_hex/sample_0/fc2.hex"),
        .TEST_NAME("tb_linear_parallel_fc2")
    ) i_tb ();
endmodule
