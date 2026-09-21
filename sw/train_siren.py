import os
import torch
import torch.nn as nn
import numpy as np
from PIL import Image

NUM_NEURONS = 32

def float_to_q4_12_hex(val):
    scaled = int(np.round(val * 4096.0))
    clamped = max(-32768, min(32767, scaled))
    raw = clamped & 0xFFFF
    return f"{raw:04x}"

class SirenLayer(nn.Module):
    def __init__(self, in_features, out_features, w0=30.0, is_first=False):
        super().__init__()
        self.in_features = in_features
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

    def forward(self, x):
        return torch.sin(self.w0 * self.linear(x))

class SirenINR(nn.Module):
    def __init__(self):
        super().__init__()
        self.l1 = SirenLayer(2, NUM_NEURONS, w0=30.0, is_first=True)
        self.l2 = nn.Linear(NUM_NEURONS, 1)
        with torch.no_grad():
            bound = np.sqrt(6.0 / NUM_NEURONS)
            self.l2.weight.uniform_(-bound, bound)
            self.l2.bias.zero_()

    def forward(self, coords):
        return self.l2(self.l1(coords))

def get_target_image(grid_size=32):
    if os.path.exists("target_photo.png"):
        img = Image.open("target_photo.png").convert("L").resize((grid_size, grid_size), Image.Resampling.BILINEAR)
        target = np.array(img, dtype=np.float32) / 255.0
    else:
        y = np.linspace(-1.0, 1.0, grid_size)
        x = np.linspace(-1.0, 1.0, grid_size)
        xx, yy = np.meshgrid(x, y)
        target = 0.5 * (np.sin(3.0 * np.pi * xx) * np.cos(3.0 * np.pi * yy) + 1.0)
    return target

def main():
    os.makedirs("sim", exist_ok=True)
    os.makedirs("doc", exist_ok=True)

    grid_size = 32
    target = get_target_image(grid_size)
    np.save("doc/target_ground_truth.npy", target)

    y = np.linspace(-1.0, 1.0, grid_size)
    x = np.linspace(-1.0, 1.0, grid_size)

    coords_list = []
    targets_list = []
    for r in range(grid_size):
        for c in range(grid_size):
            coords_list.append([x[c], y[r]])
            targets_list.append([target[r, c]])

    coords_t = torch.tensor(coords_list, dtype=torch.float32)
    targets_t = torch.tensor(targets_list, dtype=torch.float32)

    torch.manual_seed(42)
    model = SirenINR()
    
    epochs = 6000
    optimizer = torch.optim.Adam(model.parameters(), lr=4e-3)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs, eta_min=1e-5)
    
    # Custom Loss: Penalize MSE plus a penalty for predicting outside [0.0, 1.0]
    def constrained_loss(pred, target):
        mse = torch.mean((pred - target) ** 2)
        overshoot = torch.mean(torch.relu(pred - 1.0) ** 2)
        undershoot = torch.mean(torch.relu(-pred) ** 2)
        return mse + 2.0 * (overshoot + undershoot)

    print(f"[TRAIN] Fitting {NUM_NEURONS}-neuron SIREN with Dynamic Range Clamping...")
    for epoch in range(epochs):
        optimizer.zero_grad()
        pred = model(coords_t)
        loss = constrained_loss(pred, targets_t)
        loss.backward()
        optimizer.step()
        scheduler.step()

        if (epoch + 1) % 1000 == 0:
            pure_mse = torch.mean((torch.clamp(pred, 0.0, 1.0) - targets_t) ** 2).item()
            print(f"  Epoch {epoch+1:4d} | Constrained MSE: {pure_mse:.6f} | Total Loss: {loss.item():.6f}")

    with torch.no_grad():
        float_pred = torch.clamp(model(coords_t), 0.0, 1.0).numpy().reshape(grid_size, grid_size)
        mse_float = np.mean((target - float_pred) ** 2)
        psnr_float = 10.0 * np.log10(1.0 / (mse_float + 1e-12))
        print(f"[MODEL] Golden Clamped Floating-Point PSNR: {psnr_float:.2f} dB")

    with open("sim/coords.hex", "w") as f:
        for pt in coords_list:
            f.write(f"{float_to_q4_12_hex(pt[0])}\n")
            f.write(f"{float_to_q4_12_hex(pt[1])}\n")

    w1 = model.l1.linear.weight.detach().numpy()
    b1 = model.l1.linear.bias.detach().numpy()
    with open("sim/layer1_weights.hex", "w") as f:
        for n in range(NUM_NEURONS):
            f.write(f"{float_to_q4_12_hex(w1[n, 0])}\n")
            f.write(f"{float_to_q4_12_hex(w1[n, 1])}\n")

    with open("sim/layer1_biases.hex", "w") as f:
        for n in range(NUM_NEURONS):
            f.write(f"{float_to_q4_12_hex(b1[n])}\n")

    w2 = model.l2.weight.detach().numpy().flatten()
    b2 = model.l2.bias.detach().numpy().flatten()[0]
    with open("sim/layer2_weights.hex", "w") as f:
        for n in range(NUM_NEURONS):
            f.write(f"{float_to_q4_12_hex(w2[n])}\n")

    with open("sim/layer2_bias.hex", "w") as f:
        f.write(f"{float_to_q4_12_hex(b2)}\n")

    print(f"[SUCCESS] Exported calibrated parameters to sim/")

if __name__ == "__main__":
    main()
