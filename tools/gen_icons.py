#!/usr/bin/env python3
"""一次性图标生成脚本：生成 Tray 模板图标 + 应用主图标 source。

输出：
  src-tauri/icons/tray.png         22×22  黑色+alpha（macOS 模板图标）
  src-tauri/icons/tray@2x.png      44×44  retina
  src-tauri/icons/source.png       1024×1024 应用主图标 source

之后由 `pnpm tauri icon src-tauri/icons/source.png` 生成多尺寸 + icns/ico。
"""

from __future__ import annotations

import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_DIR = os.path.join(ROOT, "src-tauri", "icons")
os.makedirs(ICON_DIR, exist_ok=True)


def draw_wave(draw: ImageDraw.ImageDraw, size: int, color):
    """画一个简化的“波浪”形状，象征 windsurf。"""
    w = size
    pad = w * 0.18
    # 顶部 chevron + 底部水平线
    cx = w / 2
    top_h = w * 0.42
    bottom_h = w * 0.66

    # 顶部尖（折线）
    poly = [
        (pad, top_h),
        (cx, top_h - w * 0.2),
        (w - pad, top_h),
        (w - pad - w * 0.08, top_h + w * 0.08),
        (cx, top_h - w * 0.04),
        (pad + w * 0.08, top_h + w * 0.08),
    ]
    draw.polygon(poly, fill=color)

    # 中部小折线
    poly2 = [
        (pad + w * 0.08, top_h + w * 0.18),
        (cx, top_h + w * 0.02),
        (w - pad - w * 0.08, top_h + w * 0.18),
        (w - pad - w * 0.16, top_h + w * 0.26),
        (cx, top_h + w * 0.10),
        (pad + w * 0.16, top_h + w * 0.26),
    ]
    draw.polygon(poly2, fill=color)

    # 底部曲线（简化为粗横线）
    bar_h = w * 0.06
    draw.rounded_rectangle(
        (pad, bottom_h, w - pad, bottom_h + bar_h),
        radius=bar_h / 2,
        fill=color,
    )


def gen_tray(size: int, out_path: str) -> None:
    """模板图标：黑色 + alpha，macOS 会自动反色适配菜单栏深色/浅色。"""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw_wave(draw, size, (0, 0, 0, 255))
    img.save(out_path, "PNG")


def gen_app_source(size: int, out_path: str) -> None:
    """应用主图标：渐变背景 + 白色波浪。"""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # 圆角矩形背景（渐变近似：纵向插值两色）
    bg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bg_draw = ImageDraw.Draw(bg)
    radius = int(size * 0.22)
    bg_draw.rounded_rectangle(
        (0, 0, size, size), radius=radius, fill=(14, 165, 233, 255)
    )

    # 上下渐变叠加（top → bottom: indigo→cyan）
    grad = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    for y in range(size):
        t = y / max(size - 1, 1)
        # 起始 #6366f1，结束 #06b6d4
        r = int(99 + (6 - 99) * t)
        g = int(102 + (182 - 102) * t)
        b = int(241 + (212 - 241) * t)
        for x in range(size):
            grad.putpixel((x, y), (r, g, b, 255))

    # 用圆角矩形 alpha 蒙版裁剪渐变
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size, size), radius=radius, fill=255
    )
    bg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bg.paste(grad, (0, 0), mask)
    img = bg

    # 高光：左上 → 右下淡化。
    # 注意：椭圆从 (-0.4*size, -0.4*size) 起始，会溢出画布到圆角外。
    # 必须用 rounded-rect mask 裁剪，否则圆角外的透明区会被画上 alpha~60 的白色，
    # 叠加 macOS Dock 暗底就会显出"棕色幽灵块"（这是个隐蔽的 macOS 图标 bug）。
    hi = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    hi_draw = ImageDraw.Draw(hi)
    hi_draw.ellipse(
        (-size * 0.4, -size * 0.4, size * 0.7, size * 0.7),
        fill=(255, 255, 255, 60),
    )
    hi = hi.filter(ImageFilter.GaussianBlur(radius=size * 0.06))
    hi_clipped = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    hi_clipped.paste(hi, (0, 0), mask)  # 复用上面的 rounded-rect mask
    img = Image.alpha_composite(img, hi_clipped)

    # 白色波浪
    fg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    fg_draw = ImageDraw.Draw(fg)
    draw_wave(fg_draw, size, (255, 255, 255, 245))
    img = Image.alpha_composite(img, fg)

    img.save(out_path, "PNG")


def main() -> None:
    gen_tray(22, os.path.join(ICON_DIR, "tray.png"))
    gen_tray(44, os.path.join(ICON_DIR, "tray@2x.png"))
    gen_app_source(1024, os.path.join(ICON_DIR, "source.png"))
    print("icons generated under", ICON_DIR)


if __name__ == "__main__":
    main()
