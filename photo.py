from skimage import data, transform
from PIL import Image

# Options: data.camera(), data.coins(), or data.astronaut()
img = data.camera()

# Resize directly to 32x32
img_resized = transform.resize(img, (32, 32), anti_aliasing=True)
img_pil = Image.fromarray((img_resized * 255).astype('uint8'))
img_pil.save("target_photo.png")
print("[SUCCESS] Saved standard benchmark 'Cameraman' as target_photo.png (32x32)")
