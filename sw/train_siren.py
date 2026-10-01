import argparse
import os
import numpy as np
from PIL import Image
import torch
import torch.nn as nn
import torch.nn.functional as F

# ==============================================================================
# Hardware Precision (Signed Q4.12)
# ==============================================================================
def float_to_q4_12_hex(val):
    scaled = int(np.round(val * 4096.0))
    clamped = max(-32768, min(32767, scaled))
    raw = clamped & 0xFFFF
    return f"{raw:04x}"

def quant_q4_12_val(x):
    scale = 4096.0
    return torch.clamp(torch.round(x * scale) / scale, -8.0, 32767.0 / scale)

class Q4_12_STE(torch.autograd.Function):
    @staticmethod
    def forward(ctx, x):
        return quant_q4_12_val(x)

    @staticmethod
    def backward(ctx, grad_output):
        return grad_output

def ste_quant(x):
    return Q4_12_STE.apply(x)

# ==============================================================================
# SIREN Architecture Matching siren_network.sv
# ==============================================================================
class SirenLayer(nn.Module):
    def __init__(self, in_features, out_features, w0=30.0, is_first=False):
        super().__init__()
        self.in_features = in_features
        self.out_features = out_features
        self.w0 = w0
        self.is_first = is_first
        self.linear = nn.Linear(in_features, out_features)
        self.init_weights()

    def init_weights(self):
        with torch.no_grad():
            if self.is_first:
                bound = 1.0 / self.in_features
                self.linear.weight.uniform_(-bound, bound)
            else:
                bound = np.sqrt(6.0 / self.in_features) / self.w0
                self.linear.weight.uniform_(-bound, bound)
            self.linear.bias.uniform_(-np.pi / self.w0, np.pi / self.w0)

    def forward(self, x, quantize=False):
        if quantize:
            w = ste_quant(self.linear.weight)
            b = ste_quant(self.linear.bias)
            x_in = ste_quant(x)
            # Matches hardware: CORDIC evaluates sin(w0 * (w*x + b))
            out = torch.sin(self.w0 * F.linear(x_in, w, b))
            return ste_quant(out)
        else:
            return torch.sin(self.w0 * self.linear(x))

class SirenINR(nn.Module):
    def __init__(self, num_neurons=32, w0=30.0):
        super().__init__()
        self.num_neurons = num_neurons
        self.l1 = SirenLayer(2, num_neurons, w0=w0, is_first=True)
        self.l2 = nn.Linear(num_neurons, 1)
        with torch.no_grad():
            bound = np.sqrt(6.0 / num_neurons)
            self.l2.weight.uniform_(-bound, bound)
            self.l2.bias.zero_()

    def forward(self, coords, quantize=False):
        h = self.l1(coords, quantize=quantize)
        if quantize:
            w2 = ste_quant(self.l2.weight)
            b2 = ste_quant(self.l2.bias)
            # Hardware dot product: sum((neuron_sin * l2_w) >>> 12) + l2_bias
            prod = ste_quant(h * w2)
            accum = torch.sum(prod, dim=-1, keepdim=True) + b2
            return accum
        else:
            return self.l2(h)

# ==============================================================================
# Preprocessing & Target Image
# ==============================================================================
def get_target_image(grid_size=32):
    if os.path.exists("target_photo.png"):
        resample_filter = getattr(getattr(Image, "Resampling", Image), "BILINEAR", Image.BILINEAR)
        img = Image.open("target_photo.png").convert("L").resize((grid_size, grid_size), resample_filter)
        target = np.array(img, dtype=np.float32) / 255.0
    else:
        y = np.linspace(-1.0, 1.0, grid_size)
        x = np.linspace(-1.0, 1.0, grid_size)
        xx, yy = np.meshgrid(x, y)
        target = 0.5 * (np.sin(3.0 * np.pi * xx) * np.cos(3.0 * np.pi * yy) + 1.0)
    return target

# ==============================================================================
# Main Runner
# ==============================================================================
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--neurons", type=int, default=32)
    parser.add_argument("--w0", type=float, default=30.0)
    parser.add_argument("--epochs", type=int, default=7000)
    args = parser.parse_args()

    os.makedirs("sim", exist_ok=True)
    os.makedirs("doc", exist_ok=True)

    grid_size = 32
    target = get_target_image(grid_size)
    np.save("doc/target_ground_truth.npy", target)

    y = np.linspace(-1.0, 1.0, grid_size)
    x = np.linspace(-1.0, 1.0, grid_size)

    coords_list, targets_list = [], []
    for r in range(grid_size):
        for c in range(grid_size):
            coords_list.append([x[c], y[r]])
            targets_list.append([target[r, c]])

    coords_t = torch.tensor(coords_list, dtype=torch.float32)
    targets_t = torch.tensor(targets_list, dtype=torch.float32)

    torch.manual_seed(42)
    np.random.seed(42)
    model = SirenINR(num_neurons=args.neurons, w0=args.w0)

    # Stage 1: Float fitting for stable global convergence (first 5000 epochs)
    # Stage 2: QAT fine-tuning (last 2000 epochs)
    epochs_float = 5000
    epochs_qat = 2000

    optimizer = torch.optim.Adam(model.parameters(), lr=4e-3)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs_float, eta_min=1e-5)

    def compute_loss(pred, target):
        mse = torch.mean((pred - target) ** 2)
        overshoot = torch.mean(torch.relu(pred - 1.0) ** 2)
        undershoot = torch.mean(torch.relu(-pred) ** 2)
        return mse + 2.0 * (overshoot + undershoot)

    print(f"[STAGE 1] Float Convergence ({epochs_float} epochs, w0={args.w0})...")
    for epoch in range(epochs_float):
        optimizer.zero_grad()
        pred = model(coords_t, quantize=False)
        loss = compute_loss(pred, targets_t)
        loss.backward()
        optimizer.step()
        scheduler.step()

        if (epoch + 1) % 1000 == 0:
            eval_mse = torch.mean((torch.clamp(pred, 0.0, 1.0) - targets_t) ** 2).item()
            psnr = 10.0 * np.log10(1.0 / (eval_mse + 1e-12))
            print(f"  Epoch {epoch+1:4d} | Float PSNR: {psnr:.2f} dB | Loss: {loss.item():.6f}")

    print(f"[STAGE 2] QAT Fine-Tuning ({epochs_qat} epochs, lr=5e-4)...")
    optimizer_qat = torch.optim.Adam(model.parameters(), lr=5e-4)
    scheduler_qat = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer_qat, T_max=epochs_qat, eta_min=1e-6)

    for epoch in range(epochs_qat):
        optimizer_qat.zero_grad()
        pred = model(coords_t, quantize=True)
        loss = compute_loss(pred, targets_t)
        loss.backward()
        optimizer_qat.step()
        scheduler_qat.step()

        if (epoch + 1) % 500 == 0:
            eval_mse = torch.mean((torch.clamp(pred, 0.0, 1.0) - targets_t) ** 2).item()
            psnr = 10.0 * np.log10(1.0 / (eval_mse + 1e-12))
            print(f"  QAT Epoch {epoch+1:4d} | Simulated HW PSNR: {psnr:.2f} dB | Loss: {loss.item():.6f}")

    # Final Emulation Check
    with torch.no_grad():
        final_hw_pred = torch.clamp(model(coords_t, quantize=True), 0.0, 1.0).numpy().reshape(grid_size, grid_size)
        final_mse = np.mean((target - final_hw_pred) ** 2)
        final_psnr = 10.0 * np.log10(1.0 / (final_mse + 1e-12))
        print(f"\n[FINAL BENCHMARK] Fixed-Point Emulated PSNR: {final_psnr:.2f} dB")

    # Export to sim/
    with open("sim/coords.hex", "w") as f:
        for pt in coords_list:
            f.write(f"{float_to_q4_12_hex(pt[0])}\n")
            f.write(f"{float_to_q4_12_hex(pt[1])}\n")

    w1 = model.l1.linear.weight.detach().numpy()
    b1 = model.l1.linear.bias.detach().numpy()
    with open("sim/layer1_weights.hex", "w") as f:
        for n in range(args.neurons):
            f.write(f"{float_to_q4_12_hex(w1[n, 0])}\n")
            f.write(f"{float_to_q4_12_hex(w1[n, 1])}\n")

    with open("sim/layer1_biases.hex", "w") as f:
        for n in range(args.neurons):
            f.write(f"{float_to_q4_12_hex(b1[n])}\n")

    w2 = model.l2.weight.detach().numpy().flatten()
    b2 = model.l2.bias.detach().numpy().flatten()[0]
    with open("sim/layer2_weights.hex", "w") as f:
        for n in range(args.neurons):
            f.write(f"{float_to_q4_12_hex(w2[n])}\n")

    with open("sim/layer2_bias.hex", "w") as f:
        f.write(f"{float_to_q4_12_hex(b2)}\n")

    print(f"[SUCCESS] Exported calibrated parameters to sim/")

if __name__ == "__main__":
    main()
