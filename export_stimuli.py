import numpy as np

IMG_SIZE = 32
TOTAL_PIXELS = IMG_SIZE * IMG_SIZE
OMEGA_0 = 30.0

def float_to_q4_12_hex(val: float) -> str:
    scaled = int(np.round(val * 4096.0))
    clamped = max(-32768, min(32767, scaled))
    return f"{clamped & 0xFFFF:04x}"

if __name__ == "__main__":
    np.random.seed(42)

    # Initial layer weights and bias
    w0 = float(np.random.uniform(-1.0, 1.0))
    w1 = float(np.random.uniform(-1.0, 1.0))
    b0 = float(np.random.uniform(-0.5, 0.5))

    # weights.hex: [w_x, w_y, bias]
    with open("weights.hex", "w") as f:
        f.write(f"{float_to_q4_12_hex(w0)}\n")
        f.write(f"{float_to_q4_12_hex(w1)}\n")
        f.write(f"{float_to_q4_12_hex(b0)}\n")

    # coords.hex: x then y for each pixel in raster order
    coords_lin = np.linspace(-1.0, 1.0, IMG_SIZE)
    grid_y, grid_x = np.meshgrid(coords_lin, coords_lin, indexing="ij")
    coords = np.stack([grid_x.flatten(), grid_y.flatten()], axis=-1)

    with open("coords.hex", "w") as f:
        for x, y in coords:
            f.write(f"{float_to_q4_12_hex(x)}\n")
            f.write(f"{float_to_q4_12_hex(y)}\n")

    # Compute floating-point reference: sin(omega_0 * (w0*x + w1*y + b0))
    linear_comb = w0 * coords[:, 0] + w1 * coords[:, 1] + b0
    golden_preds = np.sin(OMEGA_0 * linear_comb)

    # Scale from [-1, 1] to [0, 1] for image viewing
    golden_img = ((golden_preds + 1.0) / 2.0).reshape(IMG_SIZE, IMG_SIZE)
    np.save("golden_image.npy", golden_img)

    print(f"Generated stimuli for {IMG_SIZE}x{IMG_SIZE} grid ({TOTAL_PIXELS} pixels).")
    print(f"Weights exported: w0={w0:.4f}, w1={w1:.4f}, b={b0:.4f}")
