import argparse
import os
import torch
import torch.nn as nn
import numpy as np
from PIL import Image

# -------------------------------------------------------------------------
# Q4.12 Fixed-Point Straight-Through Estimator (STE)
# -------------------------------------------------------------------------
class QuantizeQ4_12STE(torch.autograd.Function):
    """
    Quantizes tensor to Q4.12 signed fixed point [-8.0, 7.99975].
    Forward pass: quantizes values to discrete 1/4096 steps.
    Backward pass: passes gradient straight through (STE).
    """
    @staticmethod
    def forward(ctx, x):
        scale = 4096.0
        # Quantize and clamp to signed 16-bit range [-32768, 32767]
        q = torch.clamp(torch.round(x * scale), -32768.0, 32767.0) / scale
        return q

    @staticmethod
    def backward(ctx, grad_output):
        return grad_output


def quant_q4_12(x):
    return QuantizeQ4_12STE.apply(x)


def float_to_q4_12_hex(val):
    q_val = int(np.round(float(val) * 4096.0))
    q_val = max(-32768, min(32767, q_val))
    return f"{(q_val & 0xFFFF):04X}"


def total_variation_loss(pred_2d):
    diff_y = torch.abs(pred_2d[:, :, 1:, :] - pred_2d[:, :, :-1, :]).mean()
    diff_x = torch.abs(pred_2d[:, :, :, 1:] - pred_2d[:, :, :, :-1]).mean()
    return diff_y + diff_x


# -------------------------------------------------------------------------
# QAT-Enabled SIREN
# -------------------------------------------------------------------------
class QATSineLayer(nn.Module):
    def __init__(self, in_features, out_features, bias=True, is_first=False, omega_0=45.0):
        super().__init__()
        self.omega_0 = omega_0
        self.is_first = is_first
        self.in_features = in_features
        self.linear = nn.Linear(in_features, out_features, bias=bias)
        self.init_weights()

    def init_weights(self):
        with torch.no_grad():
            if self.is_first:
                self.linear.weight.uniform_(-1.0 / self.in_features, 1.0 / self.in_features)
            else:
                bound = np.sqrt(6.0 / self.in_features) / self.omega_0
                self.linear.weight.uniform_(-bound, bound)

    def forward(self, input):
        # Quantize weights and biases to match RTL coefficient memory
        q_w = quant_q4_12(self.linear.weight)
        q_b = quant_q4_12(self.linear.bias)
        # Affine pass emulating RTL MAC accumulation
        affine = torch.matmul(input, q_w.t()) + q_b
        q_affine = quant_q4_12(affine)
        # Activation using omega_0 matching siren_scaler.sv
        return torch.sin(self.omega_0 * q_affine)


class QATSiren(nn.Module):
    def __init__(self, in_features=2, hidden_features=64, out_features=1, omega_0=45.0):
        super().__init__()
        self.l1 = QATSineLayer(in_features, hidden_features, is_first=True, omega_0=omega_0)
        self.l2 = nn.Linear(hidden_features, out_features)
        with torch.no_grad():
            bound = np.sqrt(6.0 / hidden_features)
            self.l2.weight.uniform_(-bound, bound)
            self.l2.bias.zero_()

    def forward(self, coords):
        act = self.l1(coords)
        q_act = quant_q4_12(act)
        q_w2 = quant_q4_12(self.l2.weight)
        q_b2 = quant_q4_12(self.l2.bias)
        out = torch.matmul(q_act, q_w2.t()) + q_b2
        return quant_q4_12(out)


# -------------------------------------------------------------------------
# Training Pipeline
# -------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="QAT Training for SIREN Accelerator")
    parser.add_argument("--image", type=str, default="cameraman", help="Image name stem in test_images/")
    parser.add_argument("--neurons", type=int, default=64, help="Neurons in hidden layer")
    parser.add_argument("--w0", type=float, default=45.0, help="Omega_0 frequency factor")
    parser.add_argument("--epochs", type=int, default=3500, help="Epoch count")
    parser.add_argument("--lr", type=float, default=1.5e-3, help="Peak learning rate")
    parser.add_argument("--tv_w", type=float, default=0.008, help="TV weight for background smoothing")
    args = parser.parse_args()

    os.makedirs("sim", exist_ok=True)
    grid_size = 32

    candidates = [
        os.path.join("test_images", f"{args.image}_32x32.png"),
        os.path.join("test_images", f"{args.image}.png"),
        os.path.join("test_images", f"{args.image}.jpg"),
        os.path.join("test_images", args.image)
    ]
    selected_path = next((p for p in candidates if os.path.isfile(p)), None)
    if not selected_path:
        raise FileNotFoundError(f"Could not find '{args.image}' inside test_images/")

    print(f"[LOAD] Loading target: {selected_path}")
    resample_filter = Image.Resampling.BILINEAR if hasattr(Image, "Resampling") else Image.BILINEAR
    img = Image.open(selected_path).convert("L").resize((grid_size, grid_size), resample_filter)
    img.save("target_photo.png")

    target_np = np.array(img, dtype=np.float32) / 255.0
    target_tensor = torch.tensor(target_np).view(-1, 1)

    coords_y = np.linspace(-1.0, 1.0, grid_size, dtype=np.float32)
    coords_x = np.linspace(-1.0, 1.0, grid_size, dtype=np.float32)
    mesh_y, mesh_x = np.meshgrid(coords_y, coords_x, indexing='ij')
    coords_np = np.stack([mesh_x.flatten(), mesh_y.flatten()], axis=-1)
    # Quantize coordinates as they enter RTL inputs
    coords_tensor = quant_q4_12(torch.tensor(coords_np))

    with open("sim/coords.hex", "w") as f:
        for pt in coords_np:
            f.write(f"{float_to_q4_12_hex(pt[0])}\n")
            f.write(f"{float_to_q4_12_hex(pt[1])}\n")

    model = QATSiren(in_features=2, hidden_features=args.neurons, omega_0=args.w0)
    optimizer = torch.optim.Adam(model.parameters(), lr=args.lr)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs, eta_min=1e-5)
    loss_mse_fn = nn.MSELoss()

    print(f"[TRAIN] Running QAT for {args.epochs} epochs...")
    for epoch in range(1, args.epochs + 1):
        optimizer.zero_grad()
        pred = model(coords_tensor)
        pred_2d = pred.view(1, 1, grid_size, grid_size)

        loss_mse = loss_mse_fn(pred, target_tensor)
        loss_tv = total_variation_loss(pred_2d)
        total_loss = loss_mse + (args.tv_w * loss_tv)

        total_loss.backward()
        optimizer.step()
        scheduler.step()

        if epoch % 500 == 0 or epoch == args.epochs:
            mse_val = loss_mse.item()
            psnr = 10.0 * np.log10(1.0 / (mse_val + 1e-10))
            print(f"[Epoch {epoch:4d}/{args.epochs}] Loss: {total_loss.item():.5f} | TV: {loss_tv.item():.5f} | QAT PSNR: {psnr:.2f} dB")

    # Export strictly quantized weights
    with torch.no_grad():
        w1 = quant_q4_12(model.l1.linear.weight).cpu().numpy()
        b1 = quant_q4_12(model.l1.linear.bias).cpu().numpy()
        w2 = quant_q4_12(model.l2.weight).cpu().numpy()[0]
        b2 = quant_q4_12(model.l2.bias).cpu().numpy()[0]

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

    with open("sim/layer2_weights.hex", "w") as f:
        for n in range(args.neurons):
            f.write(f"{float_to_q4_12_hex(w2[n])}\n")

    with open("sim/layer2_bias.hex", "w") as f:
        f.write(f"{float_to_q4_12_hex(b2)}\n")

    print("[SUCCESS] Quantization-aware hex files generated successfully.")


if __name__ == "__main__":
    main()
