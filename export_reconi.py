import math
import numpy as np

IMG_SIZE = 32
TOTAL_PIXELS = IMG_SIZE * IMG_SIZE

def q4_12_hex_to_float(hex_str: str) -> float:
    val = int(hex_str, 16)
    if val >= 0x8000:
        val -= 0x10000
    return val / 4096.0

# 1. Read hardware output directly in [-1, 1]
with open("out_pixels.hex", "r") as f:
    hw_raw = [q4_12_hex_to_float(line.strip()) for line in f if line.strip()]

hw_arr = np.array(hw_raw)[:TOTAL_PIXELS]

# 2. Compute golden sine activation directly in [-1, 1]
coords = [line.strip() for line in open("coords.hex") if line.strip()]
weights = [line.strip() for line in open("weights.hex") if line.strip()]

w0 = q4_12_hex_to_float(weights[0])
w1 = q4_12_hex_to_float(weights[1])
b0 = q4_12_hex_to_float(weights[2])

golden_raw = []
for i in range(TOTAL_PIXELS):
    x = q4_12_hex_to_float(coords[2 * i])
    y = q4_12_hex_to_float(coords[2 * i + 1])
    dot = x * w0 + y * w1 + b0
    golden_raw.append(np.sin(30.0 * dot))

golden_arr = np.array(golden_raw)

# 3. Compute MSE and PSNR (Dynamic range = 2.0 for [-1, 1])
mse = np.mean((golden_arr - hw_arr) ** 2)
psnr = 100.0 if mse == 0 else 20 * math.log10(2.0 / math.sqrt(mse))

# SSIM
c1 = (0.01 * 2.0) ** 2
c2 = (0.03 * 2.0) ** 2
mu_x, mu_y = np.mean(golden_arr), np.mean(hw_arr)
sigma_x = np.var(golden_arr)
sigma_y = np.var(hw_arr)
sigma_xy = np.cov(golden_arr, hw_arr)[0, 1]

ssim = ((2 * mu_x * mu_y + c1) * (2 * sigma_xy + c2)) / (
    (mu_x**2 + mu_y**2 + c1) * (sigma_x + sigma_y + c2)
)

print("=" * 45)
print(f"  MSE:  {mse:.6e}")
print(f"  PSNR: {psnr:.2f} dB")
print(f"  SSIM: {ssim:.4f}")
print("=" * 45)
