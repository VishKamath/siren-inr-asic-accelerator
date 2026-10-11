import numpy as np
from PIL import Image
import os

os.makedirs("test_images", exist_ok=True)

# --------------------------------------------------------------------------
# Benchmark A: High-Contrast Concentric Zone / Radial Lens
# Perfect for INR/SIREN evaluation: dense harmonic gradients, clean rings, 
# zero flat-gray voids.
# --------------------------------------------------------------------------
size = 32
coords = np.linspace(-1.0, 1.0, size)
xx, yy = np.meshgrid(coords, coords)
r = np.sqrt(xx**2 + yy**2)

# Concentric sinusoidal rings with smooth falloff
zone_plate = 0.5 * (1.0 + np.cos(np.pi * 6.5 * (r**1.4)))
# Window to round frame
window = np.clip(1.3 - r, 0.0, 1.0)
target_a = np.clip(zone_plate * window, 0.0, 1.0)

img_a = Image.fromarray((target_a * 255.0).astype(np.uint8))
img_a.save("test_images/zone_plate_32x32.png")

# --------------------------------------------------------------------------
# Benchmark B: Solid Geometric IC / Transistor Block Layout
# Clean rectilinear structures, high-contrast boundaries, smooth ramps.
# --------------------------------------------------------------------------
target_b = np.full((size, size), 0.15, dtype=np.float32)

# Substrate wells & cross structures
target_b[4:28, 4:28] = 0.85
target_b[8:24, 8:24] = 0.35
target_b[12:20, 12:20] = 0.95
target_b[14:18, 2:30] = 0.65
target_b[2:30, 14:18] = 0.65

# Anti-alias with 3x3 box filter so edges are physically bandlimited
from scipy.ndimage import uniform_filter
target_b = uniform_filter(target_b, size=2)

img_b = Image.fromarray((target_b * 255.0).astype(np.uint8))
img_b.save("test_images/ic_layout_32x32.png")

# Activate Zone Plate as default
img_a.save("target_photo.png")
print("[SUCCESS] Created test_images/zone_plate_32x32.png and test_images/ic_layout_32x32.png")
print("[ACTIVE] target_photo.png set to Zone Plate pattern.")
