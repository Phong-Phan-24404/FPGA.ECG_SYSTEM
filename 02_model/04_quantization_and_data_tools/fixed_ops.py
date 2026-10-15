import numpy as np

def to_fixed(val: np.ndarray, frac_bits: int, total_bits: int = 16) -> np.ndarray:
    """Converts a float array to fixed-point integer representation with rounding and saturation.
    
    Args:
        val: Floating-point values.
        frac_bits: Number of fractional bits.
        total_bits: Total word width in bits (signed).
        
    Returns:
        Integer array representing fixed-point values.
    """
    scale = 2.0 ** frac_bits
    # Round to nearest integer (standard round half to even or standard round)
    # Using np.round which uses round-to-nearest-even (default in Python/IEEE 754)
    scaled = np.round(val * scale)
    
    # Saturate to signed total_bits representation
    min_int = -(1 << (total_bits - 1))
    max_int = (1 << (total_bits - 1)) - 1
    
    return np.clip(scaled, min_int, max_int).astype(np.int64)

def to_float(val: np.ndarray, frac_bits: int) -> np.ndarray:
    """Converts a fixed-point integer array back to floating-point representation.
    
    Args:
        val: Fixed-point integer values.
        frac_bits: Number of fractional bits.
        
    Returns:
        Float representation.
    """
    scale = 2.0 ** frac_bits
    return val.astype(np.float64) / scale

def saturate(val: np.ndarray, total_bits: int = 16) -> np.ndarray:
    """Saturates integer array to signed total_bits range."""
    min_int = -(1 << (total_bits - 1))
    max_int = (1 << (total_bits - 1)) - 1
    return np.clip(val, min_int, max_int)

def round_and_scale(val: np.ndarray, shift: int, total_bits: int = 16) -> np.ndarray:
    """Scales and rounds an integer accumulator by shifting right with round-to-nearest and saturation.
    
    Args:
        val: High-precision integer accumulator.
        shift: Right shift amount.
        total_bits: Output word size.
        
    Returns:
        Saturated and rounded output values.
    """
    if shift > 0:
        # Add rounding constant (1 << (shift - 1)) before right shift
        half = 1 << (shift - 1)
        rounded = (val + half) >> shift
    elif shift < 0:
        # Left shift
        rounded = val << (-shift)
    else:
        rounded = val
        
    return saturate(rounded, total_bits)

def fixed_conv1d(
    x: np.ndarray,      # (batch, in_channels, in_len)
    w: np.ndarray,      # (out_channels, in_channels, kernel_size)
    b: np.ndarray,      # (out_channels,)
    x_frac: int,
    w_frac: int,
    b_frac: int,
    out_frac: int,
    total_bits: int = 16
) -> np.ndarray:
    """Bit-true vectorized fixed-point 1D convolution layer.
    
    Calculates accumulator in full precision, adds bias aligned to x_frac + w_frac, 
    then rounds and saturates to out_frac and total_bits.
    """
    batch, in_channels, in_len = x.shape
    out_channels, _, kernel_size = w.shape
    out_len = in_len - kernel_size + 1
    
    # Create sliding windows of x: shape (batch, out_len, in_channels, kernel_size)
    x_windows = np.lib.stride_tricks.as_strided(
        x, 
        shape=(batch, out_len, in_channels, kernel_size),
        strides=(x.strides[0], x.strides[2], x.strides[1], x.strides[2])
    )
    
    # Multiply and sum over in_channels and kernel_size:
    # tensordot axes: sum x_windows axes 2 & 3 with w axes 1 & 2
    # Result shape: (batch, out_len, out_channels)
    acc = np.tensordot(x_windows, w, axes=((2, 3), (1, 2)))
    
    # Transpose to (batch, out_channels, out_len)
    acc = np.transpose(acc, (0, 2, 1))
    
    # Align bias to product fractional format (x_frac + w_frac)
    bias_shift = (x_frac + w_frac) - b_frac
    if bias_shift > 0:
        aligned_bias = b << bias_shift
    elif bias_shift < 0:
        aligned_bias = b >> (-bias_shift)
    else:
        aligned_bias = b
        
    acc_total = acc + aligned_bias[:, None]
    
    # Round and scale to output format
    shift = (x_frac + w_frac) - out_frac
    return round_and_scale(acc_total, shift, total_bits)

def fixed_relu(x: np.ndarray) -> np.ndarray:
    """Bit-true fixed-point ReLU activation function."""
    return np.maximum(x, 0)

def fixed_maxpool1d(x: np.ndarray, kernel_size: int = 2, stride: int = 2) -> np.ndarray:
    """Bit-true fixed-point 1D max pooling layer."""
    batch, channels, length = x.shape
    out_len = (length - kernel_size) // stride + 1
    y = np.zeros((batch, channels, out_len), dtype=np.int64)
    
    for t in range(out_len):
        start = t * stride
        end = start + kernel_size
        y[:, :, t] = np.max(x[:, :, start:end], axis=2)
        
    return y

def fixed_global_maxpool1d(x: np.ndarray) -> np.ndarray:
    """Bit-true fixed-point global 1D max pooling layer (AdaptiveMaxPool1d(1))."""
    # x shape is (batch, channels, length)
    # Output is (batch, channels, 1)
    return np.max(x, axis=2, keepdims=True)

def fixed_linear(
    x: np.ndarray,      # (batch, in_features)
    w: np.ndarray,      # (out_features, in_features)
    b: np.ndarray,      # (out_features,)
    x_frac: int,
    w_frac: int,
    b_frac: int,
    out_frac: int,
    total_bits: int = 16
) -> np.ndarray:
    """Bit-true vectorized fixed-point fully connected (linear) layer.
    
    Calculates accumulator in full precision, adds bias aligned to x_frac + w_frac,
    then rounds and saturates to out_frac and total_bits.
    """
    acc = np.dot(x, w.T)
    
    # Align bias to product fractional format (x_frac + w_frac)
    bias_shift = (x_frac + w_frac) - b_frac
    if bias_shift > 0:
        aligned_bias = b << bias_shift
    elif bias_shift < 0:
        aligned_bias = b >> (-bias_shift)
    else:
        aligned_bias = b
        
    acc_total = acc + aligned_bias[None, :]
    
    # Round and scale to output format
    shift = (x_frac + w_frac) - out_frac
    return round_and_scale(acc_total, shift, total_bits)
