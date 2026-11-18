#!/usr/bin/env python3
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import math, os, sys

out = sys.argv[1]
size = 1024
im = Image.new("RGB", (size, size), (5, 10, 22))
px = im.load()
for y in range(size):
    for x in range(size):
        r = math.sqrt((x-size*.48)**2 + (y-size*.42)**2) / (size*.9)
        glow = max(0, 1-r)
        px[x,y] = (int(5+3*glow), int(10+23*glow), int(23+62*glow))
draw = ImageDraw.Draw(im, "RGBA")
# Subtle orbit rings
for inset, alpha in [(40,35),(68,22),(95,15)]:
    draw.ellipse((inset,inset,size-inset,size-inset), outline=(0,145,255,alpha), width=4)
# Shield silhouette with layered neon edge
shield = [(512,120),(790,230),(760,560),(650,760),(512,875),(374,760),(264,560),(234,230)]
draw.polygon(shield, fill=(5,22,48,255), outline=(0,155,255,255))
draw.line(shield+[shield[0]], fill=(0,185,255,255), width=25, joint="curve")
inner = [(512,175),(730,265),(706,545),(610,700),(512,790),(414,700),(318,545),(294,265)]
draw.polygon(inner, fill=(7,19,39,255), outline=(60,150,255,210))
# Lock body and shackle
draw.rounded_rectangle((410,450,614,640), radius=34, fill=(13,88,155,255), outline=(90,205,255,255), width=14)
draw.arc((435,340,589,520), 180, 360, fill=(125,220,255,255), width=28)
draw.ellipse((490,505,534,549), fill=(225,248,255,255))
draw.rounded_rectangle((504,535,520,590), radius=8, fill=(225,248,255,255))
# ON monogram
font_path = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
font = ImageFont.truetype(font_path, 155)
bbox = draw.textbbox((0,0), "ON", font=font, stroke_width=1)
tw = bbox[2]-bbox[0]
draw.text(((size-tw)/2, 650), "ON", font=font, fill=(235,248,255,255), stroke_width=2, stroke_fill=(0,125,255,255))
# soft glow and crisp final
glow = im.filter(ImageFilter.GaussianBlur(18))
im = Image.blend(im, glow, 0.12)
im.save(out, "PNG", optimize=True)
print(f"Created {out}")
