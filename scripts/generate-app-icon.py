#!/usr/bin/env python3
import math
import os
import shutil
import struct
import subprocess
import zlib


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BUILD_DIR = os.path.join(ROOT, "build")
ICONSET = os.path.join(BUILD_DIR, "AppIcon.iconset")
OUT_DIR = os.path.join(ROOT, "Resources")
OUT_ICNS = os.path.join(OUT_DIR, "AppIcon.icns")
MASTER_SIZE = 1024


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def lerp(a, b, t):
    return a + (b - a) * t


def write_png(path, pixels, width, height):
    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    raw = bytearray()
    row_len = width * 4
    for y in range(height):
        raw.append(0)
        start = y * row_len
        raw.extend(pixels[start:start + row_len])

    data = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as f:
        f.write(data)


def rounded_rect_alpha(x, y, size):
    margin = 46.0
    radius = 220.0
    feather = 3.0
    cx = cy = size / 2.0
    hx = hy = size / 2.0 - margin
    qx = abs(x - cx) - (hx - radius)
    qy = abs(y - cy) - (hy - radius)
    ox = max(qx, 0.0)
    oy = max(qy, 0.0)
    outside = math.hypot(ox, oy) + min(max(qx, qy), 0.0) - radius
    return clamp(0.5 - outside / feather, 0.0, 1.0)


def blend_pixel(img, width, x, y, rgba):
    if x < 0 or y < 0 or x >= width or y >= width:
        return
    i = (y * width + x) * 4
    sr, sg, sb, sa = rgba
    if sa <= 0:
        return
    dr, dg, db, da = img[i], img[i + 1], img[i + 2], img[i + 3]
    s = sa / 255.0
    d = da / 255.0
    out_a = s + d * (1.0 - s)
    if out_a <= 0:
        return
    img[i] = int((sr * s + dr * d * (1.0 - s)) / out_a)
    img[i + 1] = int((sg * s + dg * d * (1.0 - s)) / out_a)
    img[i + 2] = int((sb * s + db * d * (1.0 - s)) / out_a)
    img[i + 3] = int(out_a * 255.0)


def draw_circle(img, width, cx, cy, radius, rgba):
    r = int(math.ceil(radius + 2))
    for y in range(int(cy) - r, int(cy) + r + 1):
        for x in range(int(cx) - r, int(cx) + r + 1):
            dist = math.hypot(x + 0.5 - cx, y + 0.5 - cy)
            coverage = clamp(radius + 0.75 - dist, 0.0, 1.0)
            if coverage > 0:
                blend_pixel(img, width, x, y, (rgba[0], rgba[1], rgba[2], int(rgba[3] * coverage)))


def draw_polyline(img, width, points, stroke_width, rgba):
    radius = stroke_width / 2.0
    last = None
    for a, b in zip(points, points[1:]):
        ax, ay = a
        bx, by = b
        length = max(1.0, math.hypot(bx - ax, by - ay))
        steps = max(1, int(length / 3.5))
        for i in range(steps + 1):
            t = i / steps
            x = lerp(ax, bx, t)
            y = lerp(ay, by, t)
            if last is None or math.hypot(x - last[0], y - last[1]) > 1.5:
                draw_circle(img, width, x, y, radius, rgba)
                last = (x, y)


def cubic(p0, p1, p2, p3, t):
    u = 1.0 - t
    x = u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0]
    y = u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]
    return x, y


def draw_bezier(img, width, p0, p1, p2, p3, stroke_width, rgba):
    points = [cubic(p0, p1, p2, p3, i / 120.0) for i in range(121)]
    draw_polyline(img, width, points, stroke_width, rgba)


def make_master(size):
    img = bytearray(size * size * 4)
    top = (19, 74, 88)
    bottom = (5, 18, 31)
    accent = (41, 177, 190)

    for y in range(size):
        for x in range(size):
            a = rounded_rect_alpha(x + 0.5, y + 0.5, size)
            if a <= 0:
                continue
            t = (x + y) / (2.0 * size)
            radial = clamp(1.0 - math.hypot(x - 285, y - 230) / 560.0, 0.0, 1.0)
            r = int(lerp(top[0], bottom[0], t) + radial * 28)
            g = int(lerp(top[1], bottom[1], t) + radial * 32)
            b = int(lerp(top[2], bottom[2], t) + radial * 30)
            if y > size * 0.58:
                teal = (y - size * 0.58) / (size * 0.42)
                r = int(lerp(r, accent[0] // 2, teal * 0.22))
                g = int(lerp(g, accent[1] // 2, teal * 0.22))
                b = int(lerp(b, accent[2] // 2, teal * 0.22))
            i = (y * size + x) * 4
            img[i:i + 4] = bytes((clamp(r, 0, 255), clamp(g, 0, 255), clamp(b, 0, 255), int(255 * a)))

    # Airflow strokes behind the mark.
    draw_bezier(img, size, (175, 290), (355, 195), (590, 250), (835, 215), 34, (139, 236, 240, 145))
    draw_bezier(img, size, (145, 470), (345, 365), (620, 445), (865, 365), 34, (111, 224, 232, 120))
    draw_bezier(img, size, (225, 735), (420, 670), (625, 710), (800, 640), 30, (100, 211, 224, 100))

    # Stylized W with a soft shadow.
    w = [(250, 360), (350, 700), (512, 500), (674, 700), (774, 360)]
    shadow = [(x + 0, y + 22) for x, y in w]
    draw_polyline(img, size, shadow, 104, (0, 0, 0, 80))
    draw_polyline(img, size, w, 84, (232, 255, 255, 248))
    draw_polyline(img, size, [(x, y + 6) for x, y in w], 36, (75, 213, 224, 235))

    # Tiny switch dot.
    draw_circle(img, size, 790, 670, 42, (0, 0, 0, 70))
    draw_circle(img, size, 790, 656, 36, (236, 255, 255, 245))
    draw_circle(img, size, 790, 656, 17, (55, 199, 215, 245))
    return img


def resize_average(src, src_size, dst_size):
    if src_size == dst_size:
        return bytearray(src)
    factor = src_size // dst_size
    out = bytearray(dst_size * dst_size * 4)
    area = factor * factor
    for y in range(dst_size):
        for x in range(dst_size):
            sums = [0, 0, 0, 0]
            for yy in range(factor):
                base = ((y * factor + yy) * src_size + x * factor) * 4
                for xx in range(factor):
                    i = base + xx * 4
                    sums[0] += src[i]
                    sums[1] += src[i + 1]
                    sums[2] += src[i + 2]
                    sums[3] += src[i + 3]
            j = (y * dst_size + x) * 4
            out[j:j + 4] = bytes(s // area for s in sums)
    return out


def main():
    iconutil = shutil.which("iconutil")
    if not iconutil:
        raise SystemExit("iconutil not found")

    os.makedirs(BUILD_DIR, exist_ok=True)
    os.makedirs(OUT_DIR, exist_ok=True)
    if os.path.isdir(ICONSET):
        shutil.rmtree(ICONSET)
    os.makedirs(ICONSET)

    master = make_master(MASTER_SIZE)
    specs = [
        (16, 1), (16, 2),
        (32, 1), (32, 2),
        (128, 1), (128, 2),
        (256, 1), (256, 2),
        (512, 1), (512, 2),
    ]
    for logical, scale in specs:
        pixels = logical * scale
        name = f"icon_{logical}x{logical}{'@2x' if scale == 2 else ''}.png"
        write_png(
            os.path.join(ICONSET, name),
            resize_average(master, MASTER_SIZE, pixels),
            pixels,
            pixels,
        )

    subprocess.run([iconutil, "-c", "icns", ICONSET, "-o", OUT_ICNS], check=True)
    print(OUT_ICNS)


if __name__ == "__main__":
    main()
