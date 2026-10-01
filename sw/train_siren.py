import argparse
import os
import numpy as np
from PIL import Image
import torch
import torch.nn as nn
import torch.nn.functional as F


# ==============================================================================
# Hardware Precision & QAT Primitives (Signed Q4.12)
# ==============================================================================
class QuantizeQ4_12STE(torch.autograd.Function):
  """Simulates hardware signed Q4.12 fixed-point quantization with Straight-Through Estimator (STE).

  Range: [-8.0, 7.999755859375], Resolution: 1/4096 (~0.00024414)
  """

  @staticmethod
  def forward(ctx, x):
    scale = 4096.0
    clamped = torch.clamp(x, -8.0, 32767.0 / scale)
    return torch.round(clamped * scale) / scale

  @staticmethod
  def backward(ctx, grad_output):
    return grad_output


def quant_q4_12(x):
  return QuantizeQ4_12STE.apply(x)


def float_to_q4_12_hex(val):
  scaled = int(np.round(val * 4096.0))
  clamped = max(-32768, min(32767, scaled))
  raw = clamped & 0xFFFF
  return f"{raw:04x}"


# ==============================================================================
# Network Architecture with Hardware-Matched Datapath
# ==============================================================================
class HardwareAwareSirenLayer(nn.Module):

  def __init__(self, in_features, out_features, w0=18.0, is_first=False):
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

  def forward(self, x, qat=True):
    if qat:
      w = quant_q4_12(self.linear.weight)
      b = quant_q4_12(self.linear.bias)
      x_q = quant_q4_12(x)
      acc = F.linear(x_q, w, b)
      # CORDIC computes sine; quantize output to simulate 16-bit CORDIC output precision
      return quant_q4_12(torch.sin(self.w0 * acc))
    else:
      return torch.sin(self.w0 * self.linear(x))


class HardwareAwareSirenINR(nn.Module):

  def __init__(self, num_neurons=32, w0=18.0):
    super().__init__()
    self.num_neurons = num_neurons
    self.l1 = HardwareAwareSirenLayer(
        2, num_neurons, w0=w0, is_first=True
    )
    self.l2 = nn.Linear(num_neurons, 1)
    with torch.no_grad():
      bound = np.sqrt(6.0 / num_neurons)
      self.l2.weight.uniform_(-bound, bound)
      self.l2.bias.zero_()

  def forward(self, coords, qat=True):
    h = self.l1(coords, qat=qat)
    if qat:
      w2 = quant_q4_12(self.l2.weight)
      b2 = quant_q4_12(self.l2.bias)
      # Emulate hardware: out_value = neuron_sin * l2_w, final_value = out_value >>> 12
      prod = quant_q4_12(h * w2)
      accum = torch.sum(prod, dim=-1, keepdim=True) + b2
      return accum
    else:
      return self.l2(h)


# ==============================================================================
# Dataset & Preprocessing
# ==============================================================================
def get_target_image(grid_size=32):
  if os.path.exists("target_photo.png"):
    # Fallback to Image.BILINEAR for older Pillow versions installed on lab machines
    resample_filter = getattr(
        getattr(Image, "Resampling", Image), "BILINEAR", Image.BILINEAR
    )
    img = (
        Image.open("target_photo.png")
        .convert("L")
        .resize((grid_size, grid_size), resample_filter)
    )
    target = np.array(img, dtype=np.float32) / 255.0
  else:
    y = np.linspace(-1.0, 1.0, grid_size)
    x = np.linspace(-1.0, 1.0, grid_size)
    xx, yy = np.meshgrid(x, y)
    target = 0.5 * (np.sin(3.0 * np.pi * xx) * np.cos(3.0 * np.pi * yy) + 1.0)
  return target


# ==============================================================================
# Training Pipeline
# ==============================================================================
def main():
  parser = argparse.ArgumentParser(
      description="Train Hardware-Aware SIREN Accelerator"
  )
  parser.add_argument(
      "--neurons",
      type=int,
      default=32,
      help="Hidden dimension size (e.g. 32, 64, 128)",
  )
  parser.add_argument(
      "--w0",
      type=float,
      default=None,
      help="First-layer spatial frequency parameter",
  )
  parser.add_argument(
      "--epochs", type=int, default=8000, help="Training iterations"
  )
  parser.add_argument("--lr", type=float, default=3e-3, help="Learning rate")
  args = parser.parse_args()

  # Heuristic w0 selection based on model capacity
  if args.w0 is None:
    w0_map = {32: 18.0, 64: 22.0, 128: 26.0}
    args.w0 = w0_map.get(args.neurons, 20.0)

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
  model = HardwareAwareSirenINR(num_neurons=args.neurons, w0=args.w0)

  optimizer = torch.optim.Adam(model.parameters(), lr=args.lr)
  scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
      optimizer, T_max=args.epochs, eta_min=1e-5
  )

  print(
      f"[TRAIN] Running QAT for {args.neurons}-neuron SIREN (w0={args.w0:.1f},"
      f" {args.epochs} epochs)..."
  )

  for epoch in range(args.epochs):
    optimizer.zero_grad()
    pred = model(coords_t, qat=True)

    # Dynamic boundary loss annealing: loosen early, gently tighten near end
    progress = epoch / float(args.epochs)
    boundary_weight = 0.5 if progress < 0.5 else (0.5 + 2.0 * (progress - 0.5))

    mse = torch.mean((pred - targets_t) ** 2)
    overshoot = torch.mean(torch.relu(pred - 1.0) ** 2)
    undershoot = torch.mean(torch.relu(-pred) ** 2)
    loss = mse + boundary_weight * (overshoot + undershoot)

    loss.backward()
    optimizer.step()
    scheduler.step()

    if (epoch + 1) % 1000 == 0:
      clamped_eval = torch.clamp(pred, 0.0, 1.0)
      eval_mse = torch.mean((clamped_eval - targets_t) ** 2).item()
      eval_psnr = 10.0 * np.log10(1.0 / (eval_mse + 1e-12))
      print(
          f"  Epoch {epoch+1:5d} | QAT MSE: {eval_mse:.6f} | Clamped PSNR:"
          f" {eval_psnr:.2f} dB | Total Loss: {loss.item():.6f}"
      )

  # Exact Fixed-Point Emulation Verification
  with torch.no_grad():
    final_pred = (
        torch.clamp(model(coords_t, qat=True), 0.0, 1.0)
        .numpy()
        .reshape(grid_size, grid_size)
    )
    mse_hw = np.mean((target - final_pred) ** 2)
    psnr_hw = 10.0 * np.log10(1.0 / (mse_hw + 1e-12))
    print(f"\n[MODEL] Expected Hardware Q4.12 PSNR: {psnr_hw:.2f} dB")

  # Hex Export for Icarus Verilog Testbench
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

  print(
      f"[SUCCESS] Calibrated parameters for {args.neurons} neurons exported to"
      " sim/"
  )


if __name__ == "__main__":
  main()
