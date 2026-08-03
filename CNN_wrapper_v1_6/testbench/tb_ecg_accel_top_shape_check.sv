
// Lightweight testbench to check parameter alignment at time 0.

`timescale 1ns / 1ps

module tb_ecg_accel_top_shape_check;

    import ecg_params_pkg::*;

    initial begin
        $display("==========================================================");
        $display("      RUNNING STRUCTURAL SHAPE CONSISTENCY CHECKS");
        $display("==========================================================");

        // Stage 1 -> 2: conv1 -> relu1
        if (CONV1_OUT_STEPS * CONV1_OUT_CH != 2928) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv1 output beats mismatch! Expected 2928, got %0d", CONV1_OUT_STEPS * CONV1_OUT_CH);
        end

        // Stage 2 -> 3: relu1 -> conv2
        if (CONV2_IN_STEPS != CONV1_OUT_STEPS) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv2 IN_STEPS (%0d) != conv1 OUT_STEPS (%0d)", CONV2_IN_STEPS, CONV1_OUT_STEPS);
        end
        if (CONV2_IN_CH != CONV1_OUT_CH) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv2 IN_CH (%0d) != conv1 OUT_CH (%0d)", CONV2_IN_CH, CONV1_OUT_CH);
        end

        // Stage 3 -> 4: conv2 -> relu2
        if (CONV2_OUT_STEPS * CONV2_OUT_CH != 2864) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv2 output beats mismatch! Expected 2864, got %0d", CONV2_OUT_STEPS * CONV2_OUT_CH);
        end

        // Stage 4 -> 5: relu2 -> pool1
        if (POOL1_IN_STEPS != CONV2_OUT_STEPS) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] pool1 IN_STEPS (%0d) != conv2 OUT_STEPS (%0d)", POOL1_IN_STEPS, CONV2_OUT_STEPS);
        end
        if (POOL1_CH != CONV2_OUT_CH) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] pool1 CH (%0d) != conv2 OUT_CH (%0d)", POOL1_CH, CONV2_OUT_CH);
        end

        // Stage 5 -> 6: pool1 -> conv3
        if (POOL1_OUT_STEPS * POOL1_CH != 1424) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] pool1 output beats mismatch! Expected 1424, got %0d", POOL1_OUT_STEPS * POOL1_CH);
        end
        if (CONV3_IN_STEPS != POOL1_OUT_STEPS) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv3 IN_STEPS (%0d) != pool1 OUT_STEPS (%0d)", CONV3_IN_STEPS, POOL1_OUT_STEPS);
        end
        if (CONV3_IN_CH != POOL1_CH) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv3 IN_CH (%0d) != pool1 CH (%0d)", CONV3_IN_CH, POOL1_CH);
        end

        // Stage 6 -> 7: conv3 -> relu3
        if (CONV3_OUT_STEPS * CONV3_OUT_CH != 2784) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv3 output beats mismatch! Expected 2784, got %0d", CONV3_OUT_STEPS * CONV3_OUT_CH);
        end

        // Stage 7 -> 8: relu3 -> conv4
        if (CONV4_IN_STEPS != CONV3_OUT_STEPS) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv4 IN_STEPS (%0d) != conv3 OUT_STEPS (%0d)", CONV4_IN_STEPS, CONV3_OUT_STEPS);
        end
        if (CONV4_IN_CH != CONV3_OUT_CH) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv4 IN_CH (%0d) != conv3 OUT_CH (%0d)", CONV4_IN_CH, CONV3_OUT_CH);
        end

        // Stage 8 -> 9: conv4 -> relu4
        if (CONV4_OUT_STEPS * CONV4_OUT_CH != 2720) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv4 output beats mismatch! Expected 2720, got %0d", CONV4_OUT_STEPS * CONV4_OUT_CH);
        end

        // Stage 9 -> 10: relu4 -> pool2
        if (POOL2_IN_STEPS != CONV4_OUT_STEPS) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] pool2 IN_STEPS (%0d) != conv4 OUT_STEPS (%0d)", POOL2_IN_STEPS, CONV4_OUT_STEPS);
        end
        if (POOL2_CH != CONV4_OUT_CH) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] pool2 CH (%0d) != conv4 OUT_CH (%0d)", POOL2_CH, CONV4_OUT_CH);
        end

        // Stage 10 -> 11: pool2 -> conv5
        if (POOL2_OUT_STEPS * POOL2_CH != 1344) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] pool2 output beats mismatch! Expected 1344, got %0d", POOL2_OUT_STEPS * POOL2_CH);
        end
        if (CONV5_IN_STEPS != POOL2_OUT_STEPS) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv5 IN_STEPS (%0d) != pool2 OUT_STEPS (%0d)", CONV5_IN_STEPS, POOL2_OUT_STEPS);
        end
        if (CONV5_IN_CH != POOL2_CH) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv5 IN_CH (%0d) != pool2 CH (%0d)", CONV5_IN_CH, POOL2_CH);
        end

        // Stage 11 -> 12: conv5 -> relu5
        if (CONV5_OUT_STEPS * CONV5_OUT_CH != 10240) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv5 output beats mismatch! Expected 10240, got %0d", CONV5_OUT_STEPS * CONV5_OUT_CH);
        end

        // Stage 12 -> 13: relu5 -> conv6
        if (CONV6_IN_STEPS != CONV5_OUT_STEPS) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv6 IN_STEPS (%0d) != conv5 OUT_STEPS (%0d)", CONV6_IN_STEPS, CONV5_OUT_STEPS);
        end
        if (CONV6_IN_CH != CONV5_OUT_CH) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv6 IN_CH (%0d) != conv5 OUT_CH (%0d)", CONV6_IN_CH, CONV5_OUT_CH);
        end

        // Stage 13 -> 14: conv6 -> relu6
        if (CONV6_OUT_STEPS * CONV6_OUT_CH != 9728) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] conv6 output beats mismatch! Expected 9728, got %0d", CONV6_OUT_STEPS * CONV6_OUT_CH);
        end

        // Stage 14 -> 15: relu6 -> gpool
        if (GPOOL_STEPS != CONV6_OUT_STEPS) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] gpool STEPS (%0d) != conv6 OUT_STEPS (%0d)", GPOOL_STEPS, CONV6_OUT_STEPS);
        end
        if (GPOOL_CH != CONV6_OUT_CH) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] gpool CH (%0d) != conv6 OUT_CH (%0d)", GPOOL_CH, CONV6_OUT_CH);
        end

        // Stage 15 -> 16: gpool -> fc1
        if (FC1_IN != GPOOL_CH) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] fc1 IN_FEATURES (%0d) != gpool CH (%0d)", FC1_IN, GPOOL_CH);
        end

        // Stage 17 -> 18: relu7 -> fc2
        if (FC2_IN != FC1_OUT) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] fc2 IN_FEATURES (%0d) != fc1 OUT_FEATURES (%0d)", FC2_IN, FC1_OUT);
        end

        // Stage 19 -> 20: relu8 -> fc3
        if (FC3_IN != FC2_OUT) begin
            $fatal(1, "[SHAPE_CHECK_FAIL] fc3 IN_FEATURES (%0d) != fc2 OUT_FEATURES (%0d)", FC3_IN, FC2_OUT);
        end

        $display("[SHAPE_CHECK_SUCCESS] All adjacent pipeline shapes are properly aligned! [PASS]");
        $finish;
    end

endmodule
