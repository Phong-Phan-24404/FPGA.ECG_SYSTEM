import numpy as np
import pytest
from models.common.fixed_ops import (
    to_fixed,
    to_float,
    saturate,
    round_and_scale,
    fixed_conv1d,
    fixed_relu,
    fixed_maxpool1d,
    fixed_global_maxpool1d,
    fixed_linear
)

def test_to_fixed_and_to_float():
    # Test float value conversion to fixed and back
    x = np.array([0.5, -0.25, 1.25, -1.875])
    # For Q2.14, 0.5 should be exactly 0.5 * 2^14 = 8192
    x_fixed = to_fixed(x, frac_bits=14, total_bits=16)
    expected = np.array([8192, -4096, 20480, -30720], dtype=np.int64)
    np.testing.assert_array_equal(x_fixed, expected)
    
    # Check conversion back to float
    x_float = to_float(x_fixed, frac_bits=14)
    np.testing.assert_array_equal(x_float, x)

def test_saturation():
    # Signed 16-bit range is [-32768, 32767]
    vals = np.array([40000, -40000, 32767, -32768, 0], dtype=np.int64)
    saturated = saturate(vals, total_bits=16)
    expected = np.array([32767, -32768, 32767, -32768, 0], dtype=np.int64)
    np.testing.assert_array_equal(saturated, expected)

def test_round_and_scale():
    # 5.5 in Q0 format (value 5.5, scaled = 11, shift right by 1 to represent /2)
    # 11 >> 1 = 5, with round to nearest: (11 + 1) >> 1 = 6
    val = np.array([11, 9, -9, -11], dtype=np.int64) # represents 5.5, 4.5, -4.5, -5.5
    # shift = 1 (divide by 2)
    res = round_and_scale(val, shift=1, total_bits=16)
    expected = np.array([6, 5, -4, -5], dtype=np.int64) # round to nearest
    np.testing.assert_array_equal(res, expected)

def test_fixed_relu():
    x = np.array([-10, 0, 5, -2, 100], dtype=np.int64)
    assert np.array_equal(fixed_relu(x), np.array([0, 0, 5, 0, 100]))

def test_fixed_maxpool1d():
    # Shape: (batch=1, channels=2, length=4)
    x = np.array([[[1, 5, 3, 2], [9, 2, 8, 4]]], dtype=np.int64)
    res = fixed_maxpool1d(x, kernel_size=2, stride=2)
    expected = np.array([[[5, 3], [9, 8]]], dtype=np.int64)
    np.testing.assert_array_equal(res, expected)

def test_fixed_global_maxpool1d():
    x = np.array([[[1, 5, 3, 2], [9, 2, 8, 4]]], dtype=np.int64)
    res = fixed_global_maxpool1d(x)
    expected = np.array([[[5], [9]]], dtype=np.int64)
    np.testing.assert_array_equal(res, expected)

def test_fixed_conv1d():
    # x shape: (1, 1, 5)
    x = np.array([[[100, 200, 300, 400, 500]]], dtype=np.int64)
    # w shape: (1, 1, 3)
    w = np.array([[[2, 1, -1]]], dtype=np.int64)
    # b shape: (1,)
    b = np.array([10], dtype=np.int64)
    
    # Let's say all have same frac bits (e.g. 0), and out_frac is 0
    # Convolution outputs:
    # t=0: 100*2 + 200*1 + 300*-1 + 10 = 200 + 200 - 300 + 10 = 110
    # t=1: 200*2 + 300*1 + 400*-1 + 10 = 400 + 300 - 400 + 10 = 310
    # t=2: 300*2 + 400*1 + 500*-1 + 10 = 600 + 400 - 500 + 10 = 510
    
    y = fixed_conv1d(x, w, b, x_frac=0, w_frac=0, b_frac=0, out_frac=0, total_bits=16)
    expected = np.array([[[110, 310, 510]]], dtype=np.int64)
    np.testing.assert_array_equal(y, expected)

def test_fixed_linear():
    # x shape: (1, 3)
    x = np.array([[10, 20, 30]], dtype=np.int64)
    # w shape: (2, 3)
    w = np.array([[1, -2, 3], [0, 5, -1]], dtype=np.int64)
    # b shape: (2,)
    b = np.array([5, -10], dtype=np.int64)
    
    # Output:
    # row 0, col 0: 10*1 + 20*-2 + 30*3 + 5 = 10 - 40 + 90 + 5 = 65
    # row 0, col 1: 10*0 + 20*5 + 30*-1 - 10 = 0 + 100 - 30 - 10 = 60
    
    y = fixed_linear(x, w, b, x_frac=0, w_frac=0, b_frac=0, out_frac=0, total_bits=16)
    expected = np.array([[65, 60]], dtype=np.int64)
    np.testing.assert_array_equal(y, expected)
