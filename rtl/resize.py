import numpy as np
from PIL import Image, ImageDraw

size = 32
img = Image.new("L", (size, size), color=235)  # Light gray background
draw = ImageDraw.Draw(img)

# Solid Chess Knight Silhouette (coords tuned for a 32x32 raster)
head_polygon = [
    (15, 4),   # Tip of ear
    (18, 5),   # Back of head
    (21, 9),   # Crown curve
    (22, 17),  # Back of neck
    (22, 21),  # Lower back
    (11, 21),  # Lower chest
    (11, 16),  # Throat
    (9, 13),   # Chin / lower jaw
    (8, 11),   # Snout tip
    (11, 8),   # Forehead
    (13, 8),   # Ear base
]

draw.polygon(head_polygon, fill=25)                # Solid dark body
draw.rectangle([9, 21, 23, 25], fill=25)           # Upper base tier
draw.rectangle([7, 25, 25, 28], fill=25)           # Lower base tier

img.save("target_photo.png")
print("[SUCCESS] Created clean solid silhouette in target_photo.png")
