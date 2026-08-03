
package ecg_params_pkg;

    // Global bit-width specifications
    localparam int DATA_WIDTH   = 16;  // Activation precision (Q8.8)
    localparam int WEIGHT_WIDTH = 16;  // Weight/Bias precision (Q2.14)
    localparam int ACC_WIDTH    = 40;  // Accumulator precision (Q18.22)

    // Layer 1: Conv1d
    localparam int CONV1_IN_CH     = 1;
    localparam int CONV1_OUT_CH    = 16;
    localparam int CONV1_K         = 5;
    localparam int CONV1_S         = 1;
    localparam int CONV1_IN_STEPS  = 187;
    localparam int CONV1_OUT_STEPS = 183; // 187 - 5 + 1

    // Layer 2: Conv1d
    localparam int CONV2_IN_CH     = 16;
    localparam int CONV2_OUT_CH    = 16;
    localparam int CONV2_K         = 5;
    localparam int CONV2_S         = 1;
    localparam int CONV2_IN_STEPS  = 183;
    localparam int CONV2_OUT_STEPS = 179; // 183 - 5 + 1

    // Layer 3: MaxPool1d (Pool1)
    localparam int POOL1_CH        = 16;
    localparam int POOL1_K         = 2;
    localparam int POOL1_S         = 2;
    localparam int POOL1_IN_STEPS  = 179;
    localparam int POOL1_OUT_STEPS = 89;  // floor((179 - 2)/2) + 1

    // Layer 4: Conv1d
    localparam int CONV3_IN_CH     = 16;
    localparam int CONV3_OUT_CH    = 32;
    localparam int CONV3_K         = 3;
    localparam int CONV3_S         = 1;
    localparam int CONV3_IN_STEPS  = 89;
    localparam int CONV3_OUT_STEPS = 87;  // 89 - 3 + 1

    // Layer 5: Conv1d
    localparam int CONV4_IN_CH     = 32;
    localparam int CONV4_OUT_CH    = 32;
    localparam int CONV4_K         = 3;
    localparam int CONV4_S         = 1;
    localparam int CONV4_IN_STEPS  = 87;
    localparam int CONV4_OUT_STEPS = 85;  // 87 - 3 + 1

    // Layer 6: MaxPool1d (Pool2)
    localparam int POOL2_CH        = 32;
    localparam int POOL2_K         = 2;
    localparam int POOL2_S         = 2;
    localparam int POOL2_IN_STEPS  = 85;
    localparam int POOL2_OUT_STEPS = 42;  // floor((85 - 2)/2) + 1

    // Layer 7: Conv1d
    localparam int CONV5_IN_CH     = 32;
    localparam int CONV5_OUT_CH    = 256;
    localparam int CONV5_K         = 3;
    localparam int CONV5_S         = 1;
    localparam int CONV5_IN_STEPS  = 42;
    localparam int CONV5_OUT_STEPS = 40;  // 42 - 3 + 1

    // Layer 8: Conv1d
    localparam int CONV6_IN_CH     = 256;
    localparam int CONV6_OUT_CH    = 256;
    localparam int CONV6_K         = 3;
    localparam int CONV6_S         = 1;
    localparam int CONV6_IN_STEPS  = 40;
    localparam int CONV6_OUT_STEPS = 38;  // 40 - 3 + 1

    // Layer 9: GlobalMaxPool1d
    localparam int GPOOL_CH        = 256;
    localparam int GPOOL_STEPS     = 38;

    // Layer 10: FC1 (Linear)
    localparam int FC1_IN          = 256;
    localparam int FC1_OUT         = 64;

    // Layer 11: FC2 (Linear)
    localparam int FC2_IN          = 64;
    localparam int FC2_OUT         = 64;

    // Layer 12: FC3 (Linear)
    localparam int FC3_IN          = 64;
    localparam int FC3_OUT         = 5;

endpackage
