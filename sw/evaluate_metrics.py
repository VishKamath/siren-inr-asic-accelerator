import os
import numpy as np
import matplotlib.pyplot as plt
from PIL import Image

def q4_12_hex_to_float(hex_str):
    raw = int(hex_str.strip(), 16)
    if raw >= 0x8000:
        raw -= 0x10000
    return raw / 4096.0

def compute_ssim(img1, img2):
    C1 = (0.01 * 1.0) ** 2
    C2 = (0.03 * 1.0) ** 2
    mu1 = np.mean(img1)
    mu2 = np.mean(img2)
    sigma1_sq = np.var(img1)
    sigma2_sq = np.var(img2)
    sigma12 = np.mean((img1 - mu1) * (img2 - mu2))
    ssim = ((2.0 * mu1 * mu2 + C1) * (2.0 * sigma12 + C2)) / \
           ((mu1 ** 2 + mu2 ** 2 + C1) * (sigma1_sq + sigma2_sq + C2))
    return float(ssim)

def main():
    hex_path = "sim/out_pixels.hex"
    gt_path  = "doc/target_ground_truth.npy"

    if not os.path.exists(hex_path):
        print(f"[ERROR] Simulation output file not found: {hex_path}")
        return

    with open(hex_path, "r") as f:
        lines = [line.strip() for line in f if line.strip()]

    if len(lines) < 1024:
        print(f"[ERROR] Found only {len(lines)} pixels in {hex_path}, expected 1024.")
        return

    pixels = [q4_12_hex_to_float(h) for h in lines[:1024]]
    recon = np.array(pixels, dtype=np.float32).reshape(32, 32)
    recon = np.clip(recon, 0.0, 1.0)

    # Load the exact ground truth array saved during training
    if os.path.exists(gt_path):
        target = np.load(gt_path)
    elif os.path.exists("target_photo.png"):
        img = Image.open("target_photo.png").convert("L").resize((32, 32), Image.Resampling.BILINEAR)
        target = np.array(img, dtype=np.float32) / 255.0
        target = (target - target.min()) / (target.max() - target.min() + 1e-8)
    else:
        y = np.linspace(-1.0, 1.0, 32)
        x = np.linspace(-1.0, 1.0, 32)
        xx, yy = np.meshgrid(x, y)
        target = 0.5 * (np.sin(3.0 * np.pi * xx) * np.cos(3.0 * np.pi * yy) + 1.0)

    mse = np.mean((target - recon) ** 2)
    psnr = 10.0 * np.log10(1.0 / (mse + 1e-12))
    ssim = compute_ssim(target, recon)

    print("==================================================")
    print("        HARDWARE RECONSTRUCTION EVALUATION        ")
    print("==================================================")
    print(f" Mean Squared Error (MSE) : {mse:.6f}")
    print(f" Peak SNR (PSNR)          : {psnr:.2f} dB")
    print(f" Structural Sim. (SSIM)   : {ssim:.4f}")
    print("==================================================")

    fig, axes = plt.subplots(1, 2, figsize=(8, 4))
    axes[0].imshow(target, cmap="gray", vmin=0, vmax=1)
    axes[0].set_title("Ground Truth (Target)")
    axes[0].axis("off")

    axes[1].imshow(recon, cmap="gray", vmin=0, vmax=1)
    axes[1].set_title(f"RTL Output (Q4.12)\nPSNR: {psnr:.2f} dB | SSIM: {ssim:.4f}")
    axes[1].axis("off")

    plt.tight_layout()
    plt.savefig("doc/reconstructed_output.png", dpi=200)
    print("[INFO] Saved side-by-side reconstruction plot to doc/reconstructed_output.png")

if __name__ == "__main__":
    main()
