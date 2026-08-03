
// Self-checking testbench for q_round_saturate module.
// Classification: Math unit test (N/A for resets/handshakes/stalls).

`timescale 1ns / 1ps

module tb_math_helper;

    localparam int N = 40;
    localparam int M = 16;
    localparam int SHIFT = 14;

    logic signed [N-1:0] accumulator;
    logic signed [M-1:0] saturated_out;

    // Instantiate DUT
    q_round_saturate #(
        .N(N),
        .M(M),
        .SHIFT(SHIFT)
    ) dut (
        .accumulator(accumulator),
        .saturated_out(saturated_out)
    );

    int errors = 0;

    initial begin
        $display("==================================================");
        $display("Running tb_math_helper...");
        $display("NOTE: This is a math unit test for q_round_saturate.");
        $display("==================================================");

        // Testcase 1: 0x00000450 -> 0x0000
        accumulator = 40'h0000000450;
        #10;
        if (saturated_out === 16'h0000) begin
            $display("[PASS] TC1: Input 0x00000450 -> Output 0x%04H", saturated_out);
        end else begin
            $display("[ERROR] module=q_round_saturate, test_name=tb_math_helper, vector_path=N/A, expected_path=N/A, transaction_index=0, time_index=0, channel_index=0, expected=0x0000, actual=0x%04H, delta=%d, cycle=0, seed=0", 
                     saturated_out, int'(saturated_out) - int'(16'h0000));
            errors = errors + 1;
        end

        // Testcase 2: 0x00021A40 -> 0x0008
        accumulator = 40'h0000021A40;
        #10;
        if (saturated_out === 16'h0008) begin
            $display("[PASS] TC2: Input 0x00021A40 -> Output 0x%04H", saturated_out);
        end else begin
            $display("[ERROR] module=q_round_saturate, test_name=tb_math_helper, vector_path=N/A, expected_path=N/A, transaction_index=1, time_index=0, channel_index=0, expected=0x0008, actual=0x%04H, delta=%d, cycle=0, seed=0", 
                     saturated_out, int'(saturated_out) - int'(16'h0008));
            errors = errors + 1;
        end

        // Testcase 3: 0xFFFFDBB0 -> 0xFFFF
        accumulator = 40'hFFFFFFFDBB0;
        #10;
        if (saturated_out === 16'hFFFF) begin
            $display("[PASS] TC3: Input 0xFFFFDBB0 -> Output 0x%04H", saturated_out);
        end else begin
            $display("[ERROR] module=q_round_saturate, test_name=tb_math_helper, vector_path=N/A, expected_path=N/A, transaction_index=2, time_index=0, channel_index=0, expected=0xFFFF, actual=0x%04H, delta=%d, cycle=0, seed=0", 
                     saturated_out, int'(saturated_out) - int'(16'hFFFF));
            errors = errors + 1;
        end

        // Testcase 4: 0x002B4000 -> 0x7FFF (Saturated)
        accumulator = 40'h002B400000;
        #10;
        if (saturated_out === 16'h7FFF) begin
            $display("[PASS] TC4: Input 0x002B4000 -> Output 0x%04H (Saturated)", saturated_out);
        end else begin
            $display("[ERROR] module=q_round_saturate, test_name=tb_math_helper, vector_path=N/A, expected_path=N/A, transaction_index=3, time_index=0, channel_index=0, expected=0x7FFF, actual=0x%04H, delta=%d, cycle=0, seed=0", 
                     saturated_out, int'(saturated_out) - int'(16'h7FFF));
            errors = errors + 1;
        end

        $display("==================================================");
        if (errors == 0) begin
            $display("All tests in tb_math_helper passed! [SUCCESS]");
        end else begin
            $display("tb_math_helper failed with %d errors. [FAIL]", errors);
        end
        $display("==================================================");
        $finish;
    end

endmodule
