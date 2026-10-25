"""Place a downloaded icon on a white 1024x1024 canvas with no alpha channel (App Store icon rules)."""
import sys
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
img = Image.open(src).convert("RGBA")
size = 1024
canvas = Image.new("RGB", (size, size), (255, 255, 255))
scale = (size * 0.7) / max(img.size)
img = img.resize((max(1, int(img.width * scale)), max(1, int(img.height * scale))), Image.LANCZOS)
canvas.paste(img, ((size - img.width) // 2, (size - img.height) // 2), img)
canvas.save(dst, "PNG")
