import numpy as np

# ==============================================================================
# 1. FIXED-POINT QUANTIZATION & FILE I/O HELPERS
# ==============================================================================
def to_fixed(val, total_bits, frac_bits):
    """
    Converts floating point numbers to signed two's complement fixed-point integers.
    Clips out-of-range values to prevent arithmetic overflow.
    """
    scale = 1 << frac_bits
    q = np.round(val * scale).astype(np.int64)
    min_val = -(1 << (total_bits - 1))
    max_val = (1 << (total_bits - 1)) - 1
    return np.clip(q, min_val, max_val)

def to_hex_str(val, bits):
    """Formats an integer into a two's complement hexadecimal string."""
    mask = (1 << bits) - 1
    hex_len = (bits + 3) // 4
    val_int = int(val) & mask
    return f"{val_int:0{hex_len}X}"

def save_mem_file(filename, data_array, bits):
    """Writes flattened array values line-by-line in hex for Verilog $readmemh."""
    flat_data = np.asarray(data_array).flatten()
    with open(filename, "w") as f:
        for val in flat_data:
            f.write(f"{to_hex_str(val, bits)}\n")
    print(f"[Exported] {filename:<22} | Entries: {len(flat_data):<5} | Width: {bits}-bit")

# ==============================================================================
# 2. GENERATE SYNTHETIC MEDICAL TEST PATTERN & COORDINATE GRID
# ==============================================================================
# 16x16 grid (256 voxels) for rapid RTL simulation cycles
IMG_H, IMG_W = 16, 16
NUM_VOXELS   = IMG_H * IMG_W

# Synthetic concentric ring pattern resembling a CT/MRI tissue cross-section
y_grid, x_grid = np.ogrid[:IMG_H, :IMG_W]
center_y, center_x = (IMG_H - 1) / 2.0, (IMG_W - 1) / 2.0
dist = np.sqrt((x_grid - center_x)**2 + (y_grid - center_y)**2)
max_r = np.sqrt(center_x**2 + center_y**2)

target_image = 0.5 + 0.5 * np.cos(dist / max_r * np.pi * 2.0)
targets = target_image.flatten().reshape(-1, 1)

# Input coordinates normalized to [-1.0, 1.0)
x_coords = np.linspace(-1.0, 1.0, IMG_W, endpoint=False)
y_coords = np.linspace(-1.0, 1.0, IMG_H, endpoint=False)
xx, yy = np.meshgrid(x_coords, y_coords)
coords = np.stack([xx.flatten(), yy.flatten(), np.zeros(NUM_VOXELS)], axis=-1)

# ==============================================================================
# 3. INR MODEL SETUP & ADAM TRAINING LOOP (PURE NUMPY)
# ==============================================================================
np.random.seed(42)

# Fourier Feature Matrix B: (3 coords x 4 projections) -> 8 trigonometric features
B = np.random.normal(0.0, 1.5, size=(3, 4))
proj = 2.0 * np.pi * np.dot(coords, B)
X_features = np.concatenate([np.sin(proj), np.cos(proj)], axis=-1)  # Shape: (256, 8)

# MLP Dimensions: 8 -> 32 -> 32 -> 1
HIDDEN = 32
W1 = np.random.randn(8, HIDDEN) * np.sqrt(2.0 / 8)
W2 = np.random.randn(HIDDEN, HIDDEN) * np.sqrt(2.0 / HIDDEN)
W3 = np.random.randn(HIDDEN, 1) * np.sqrt(2.0 / HIDDEN)

# Adam Optimizer Parameters
lr = 0.01
epochs = 400
beta1, beta2, eps = 0.9, 0.999, 1e-8
m_w1, v_w1 = np.zeros_like(W1), np.zeros_like(W1)
m_w2, v_w2 = np.zeros_like(W2), np.zeros_like(W2)
m_w3, v_w3 = np.zeros_like(W3), np.zeros_like(W3)

print("Training INR model on synthetic slice...")
for epoch in range(1, epochs + 1):
    # Forward Pass
    Z1 = np.dot(X_features, W1)
    A1 = np.maximum(0, Z1)  # ReLU
    
    Z2 = np.dot(A1, W2)
    A2 = np.maximum(0, Z2)  # ReLU
    
    pred = np.dot(A2, W3)   # Linear output
    
    loss = np.mean((pred - targets)**2)
    
    # Backpropagation
    dpred = (2.0 / NUM_VOXELS) * (pred - targets)
    dW3 = np.dot(A2.T, dpred)
    
    dA2 = np.dot(dpred, W3.T)
    dZ2 = dA2 * (Z2 > 0)
    dW2 = np.dot(A1.T, dZ2)
    
    dA1 = np.dot(dZ2, W2.T)
    dZ1 = dA1 * (Z1 > 0)
    dW1 = np.dot(X_features.T, dZ1)
    
    # Adam Updates
    m_w1 = beta1 * m_w1 + (1 - beta1) * dW1
    v_w1 = beta2 * v_w1 + (1 - beta2) * (dW1**2)
    W1 -= lr * (m_w1 / (1 - beta1**epoch)) / (np.sqrt(v_w1 / (1 - beta2**epoch)) + eps)
    
    m_w2 = beta1 * m_w2 + (1 - beta1) * dW2
    v_w2 = beta2 * v_w2 + (1 - beta2) * (dW2**2)
    W2 -= lr * (m_w2 / (1 - beta1**epoch)) / (np.sqrt(v_w2 / (1 - beta2**epoch)) + eps)
    
    m_w3 = beta1 * m_w3 + (1 - beta1) * dW3
    v_w3 = beta2 * v_w3 + (1 - beta2) * (dW3**2)
    W3 -= lr * (m_w3 / (1 - beta1**epoch)) / (np.sqrt(v_w3 / (1 - beta2**epoch)) + eps)

print(f"Training completed. Final Mean Squared Error: {loss:.6f}\n")

# ==============================================================================
# 4. FIXED-POINT FORWARD SIMULATION (HARDWARE SPEC ACCURATE)
# ==============================================================================
# Spec Bit-Widths
COORD_BITS  = 16; COORD_FRAC  = 14   # Q2.14
FMAT_BITS   = 16; FMAT_FRAC   = 14   # Q2.14
WEIGHT_BITS = 10; WEIGHT_FRAC = 8    # Q2.8
ACT_BITS    = 16; ACT_FRAC    = 12   # Q4.12
OUT_BITS    = 8                      # 8-bit uint

coords_q = to_fixed(coords, COORD_BITS, COORD_FRAC)
B_q      = to_fixed(B, FMAT_BITS, FMAT_FRAC)
W1_q     = to_fixed(W1, WEIGHT_BITS, WEIGHT_FRAC)
W2_q     = to_fixed(W2, WEIGHT_BITS, WEIGHT_FRAC)
W3_q     = to_fixed(W3, WEIGHT_BITS, WEIGHT_FRAC)

# Run full fixed-point forward pass to generate golden intermediate outputs
golden_ffm_list    = []
golden_l1_list     = []
golden_l2_list     = []
golden_pixels_list = []

for i in range(NUM_VOXELS):
    # FFM projection: 12-MAC
    coord_vec = coords_q[i]
    proj_32b  = np.dot(coord_vec.astype(np.int64), B_q.astype(np.int64))
    
    # Scale to CORDIC angle input in [-pi, pi) -> Q1.15
    angles_q15 = np.clip(proj_32b >> (COORD_FRAC + FMAT_FRAC - 15), -(1 << 15), (1 << 15) - 1)
    angles_rad = (angles_q15 / (1 << 15)) * np.pi
    
    # CORDIC sin/cos output in Q4.12
    sin_q = to_fixed(np.sin(angles_rad), ACT_BITS, ACT_FRAC)
    cos_q = to_fixed(np.cos(angles_rad), ACT_BITS, ACT_FRAC)
    ffm_features = np.concatenate([sin_q, cos_q])
    golden_ffm_list.append(ffm_features)
    
    # Layer 1: MAC + Arithmetic Shift + ReLU
    l1_accum = np.dot(ffm_features.astype(np.int64), W1_q.astype(np.int64))
    l1_scaled = np.clip(l1_accum >> WEIGHT_FRAC, -(1 << (ACT_BITS - 1)), (1 << (ACT_BITS - 1)) - 1)
    l1_act = np.maximum(0, l1_scaled)
    golden_l1_list.append(l1_act)
    
    # Layer 2: MAC + Arithmetic Shift + ReLU
    l2_accum = np.dot(l1_act.astype(np.int64), W2_q.astype(np.int64))
    l2_scaled = np.clip(l2_accum >> WEIGHT_FRAC, -(1 << (ACT_BITS - 1)), (1 << (ACT_BITS - 1)) - 1)
    l2_act = np.maximum(0, l2_scaled)
    golden_l2_list.append(l2_act)
    
    # Layer 3: Linear Output -> 8-bit Intensity [0, 255]
    out_accum = np.dot(l2_act.astype(np.int64), W3_q.astype(np.int64))
    out_pixel = np.clip(out_accum >> (WEIGHT_FRAC + ACT_FRAC - 4), 0, 255).astype(np.uint8)
    golden_pixels_list.append(out_pixel)

# ==============================================================================
# 5. EXPORT VERILOG TESTBENCH MEMORY FILES
# ==============================================================================
print("Exporting Verilog memory files...")
save_mem_file("input_coords.mem",    coords_q,           COORD_BITS)
save_mem_file("fourier_matrix.mem",  B_q,                FMAT_BITS)
save_mem_file("weights_l1.mem",      W1_q,               WEIGHT_BITS)
save_mem_file("weights_l2.mem",      W2_q,               WEIGHT_BITS)
save_mem_file("weights_l3.mem",      W3_q,               WEIGHT_BITS)
save_mem_file("expected_ffm.mem",    golden_ffm_list,    ACT_BITS)
save_mem_file("expected_l1.mem",     golden_l1_list,     ACT_BITS)
save_mem_file("expected_l2.mem",     golden_l2_list,     ACT_BITS)
save_mem_file("expected_image.mem",  golden_pixels_list, OUT_BITS)

print("\nGolden reference setup complete. All stimulus files are ready.")