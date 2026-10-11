import numpy as np
from PIL import Image
import matplotlib.pyplot as plt
import os
from skimage.metrics import peak_signal_noise_ratio as psnr_fn
from skimage.metrics import structural_similarity as ssim_fn

def load_pixels(filename):
    if not os.path.exists(filename):
        print(f"[ERROR] Missing file: {filename}")
        return np.zeros((32, 32), dtype=np.float32)
    with open(filename, "r") as f:
        vals = [float(line.strip()) for line in f if line.strip()]
    if len(vals) < 1024:
        vals += [0.0] * (1024 - len(vals))
    arr = np.array(vals[:1024], dtype=np.float32) / 4096.0
    return np.clip(arr.reshape((32, 32)), 0.0, 1.0)

# Load ground truth
target_img = Image.open("target_photo.png").convert("L").resize((32, 32))
target_arr = np.array(target_img, dtype=np.float32) / 255.0

# Load simulation outputs
raw_arr   = load_pixels("raw_pixels.txt")
sharp_arr = load_pixels("sharpened_pixels.txt")
clamp_arr = load_pixels("clamped_pixels.txt")

# Calculate metrics
p_raw   = psnr_fn(target_arr, raw_arr, data_range=1.0)
s_raw   = ssim_fn(target_arr, raw_arr, data_range=1.0)

p_sharp = psnr_fn(target_arr, sharp_arr, data_range=1.0)
s_sharp = ssim_fn(target_arr, sharp_arr, data_range=1.0)

p_clamp = psnr_fn(target_arr, clamp_arr, data_range=1.0)
s_clamp = ssim_fn(target_arr, clamp_arr, data_range=1.0)

print(f"Raw INR Output:    PSNR = {p_raw:.2f} dB | SSIM = {s_raw:.4f}")
print(f"Sharpened Output:  PSNR = {p_sharp:.2f} dB | SSIM = {s_sharp:.4f}")
print(f"Clamped Output:    PSNR = {p_clamp:.2f} dB | SSIM = {s_clamp:.4f}")

# Plot 4-Panel Figure
fig, axes = plt.subplots(1, 4, figsize=(20, 5))

axes[0].imshow(target_arr, cmap='gray', vmin=0, vmax=1)
axes[0].set_title("Ground Truth (Target)", fontsize=13)
axes[0].axis('off')

axes[1].imshow(raw_arr, cmap='gray', vmin=0, vmax=1)
axes[1].set_title(f"Raw INR Output\nPSNR: {p_raw:.2f} dB | SSIM: {s_raw:.4f}", fontsize=13)
axes[1].axis('off')

axes[2].imshow(sharp_arr, cmap='gray', vmin=0, vmax=1)
axes[2].set_title(f"Sharpened (8-Neighbor)\nPSNR: {p_sharp:.2f} dB | SSIM: {s_sharp:.4f}", fontsize=13)
axes[2].axis('off')

axes[3].imshow(clamp_arr, cmap='gray', vmin=0, vmax=1)
axes[3].set_title(f"Clamped (ACRC Final)\nPSNR: {p_clamp:.2f} dB | SSIM: {s_clamp:.4f}", fontsize=13)
axes[3].axis('off')

plt.tight_layout()
plt.savefig("doc/reconstructed_output.png", dpi=300)
print("[SAVED] Saved comparison to reconstructed_output.png")
