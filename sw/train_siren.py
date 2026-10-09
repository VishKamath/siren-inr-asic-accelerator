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
# SIREN Architecture Matching siren_block_engine.sv
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
            
            # Layer-1 dot product & affine sum in Q4.12
            affine = F.linear(x_in, w, b)
            affine_q = ste_quant(affine)
            
            # Phase scaling & wrapping to [-pi, +pi] (matching siren_scaler.sv)
            raw_angle = self.w0 * affine_q
            wrapped_angle = torch.remainder(raw_angle + np.pi, 2.0 * np.pi) - np.pi
            
            out = torch.sin(wrapped_angle)
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
            
            # Exact hardware emulation: round products to Q4.12, then accumulate with bias
            prod = ste_quant(h * w2)
            accum = torch.sum(prod, dim=-1, keepdim=True) + b2
            return ste_quant(accum)
        else:
            return self.l2(h)

# ==============================================================================
# Preprocessing & Target Image
# ==============================================================================
def get_target_image(grid_size=32):
    if os.path.exists("target_photo.png"):
        resample_filter = getattr(getattr(Image, "Resampling", Image), "LANCZOS", Image.BILINEAR)
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

    epochs_float = 5000
    epochs_qat   = 2000

    optimizer = torch.optim.Adam(model.parameters(), lr=3e-3)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs_float, eta_min=1e-5)

    def compute_loss(pred, target):
        mse = torch.mean((pred - target) ** 2)
        pred_2d = pred.view(grid_size, grid_size)
        tv_h = torch.mean(torch.abs(pred_2d[1:, :] - pred_2d[:-1, :]))
        tv_w = torch.mean(torch.abs(pred_2d[:, 1:] - pred_2d[:, :-1]))
        tv_loss = tv_h + tv_w

        overshoot  = torch.mean(torch.relu(pred - 1.0) ** 2)
        undershoot = torch.mean(torch.relu(-pred) ** 2)
        return mse + 0.003 * tv_loss + 2.0 * (overshoot + undershoot)

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

    # Golden Diagnostics for Pixel 0
    with torch.no_grad():
        h0 = model.l1(coords_t[0:1], quantize=True)
        w2_q = ste_quant(model.l2.weight)
        b2_q = ste_quant(model.l2.bias)
        p0 = ste_quant(h0 * w2_q)
        acc0 = torch.sum(p0, dim=-1, keepdim=True) + b2_q
        pix0_val = torch.clamp(acc0, 0.0, 1.0).item()

        print("\n" + "="*60)
        print("          GOLDEN REFERENCE DEBUG (PIXEL 0: x=-1.0, y=-1.0)")
        print("="*60)
        print(f"Target Ground Truth Value    : {targets_t[0].item():.4f}")
        print(f"Golden Acc Output (Float)    : {acc0.item():.4f}")
        print(f"Golden Clamped Pixel [0, 1]  : {pix0_val:.4f} (Hex: 0x{float_to_q4_12_hex(pix0_val)})")
        print(f"Layer-2 Bias (b2)            : {b2_q.item():.4f} (Hex: 0x{float_to_q4_12_hex(b2_q.item())})")
        
        print("\nPass 0 (Neurons 0..3):")
        for i in range(4):
            act_hex = float_to_q4_12_hex(h0[0, i].item())
            w2_hex  = float_to_q4_12_hex(w2_q[0, i].item())
            prod_val = p0[0, i].item()
            print(f"  Neuron {i:2d}: act={act_hex} ({h0[0,i].item():+.3f}), w2={w2_hex} ({w2_q[0,i].item():+.3f}) -> prod={prod_val:+.4f}")
        print("="*60 + "\n")

    # Export parameter hex files
    with open("sim/coords.hex", "w") as f:
        for pt in coords_list:
            f.write(f"{float_to_q4_12_hex(pt[0])}\n")
            f.write(f"{float_to_q4_12_hex(pt[1])}\n")

    w1 = model.l1.linear.weight.detach().numpy()
    b1 = model.l1.linear.bias.detach().numpy()

    with open("sim/layer1_weights_x.hex", "w") as fx, open("sim/layer1_weights_y.hex", "w") as fy:
        for n in range(args.neurons):
            fx.write(f"{float_to_q4_12_hex(w1[n, 0])}\n")
            fy.write(f"{float_to_q4_12_hex(w1[n, 1])}\n")

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

    print("[SUCCESS] Exported calibrated parameters to sim/")

if __name__ == "__main__":
    main()
