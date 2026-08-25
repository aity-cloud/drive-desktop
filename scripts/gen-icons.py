#!/usr/bin/env python3
"""Generate the Aity Drive OEM theme icon set from the brand master.

Source of truth: ../meta/brand/logo.svg (the Aity mark - two embedded PNG
layers positioned on a 197x197 canvas; see meta/brand/README.md). This
script derives every raster/vector asset the upstream OEM theme mechanism
consumes at the Pin (THEME.cmake + OCBundleResources.cmake + ecm_add_app_icon):

  overlay/production/theme/colored/<N>-aitydrive-icon.png       app icon set
  overlay/production/theme/colored/<N>-aitydrive-sidebar.png    macOS sidebar
  overlay/production/theme/universal/aitydrive-icon.svg         runtime icon
  overlay/staging/...  same, named aitydrive-staging, with an STG badge
  overlay/common/theme/universal/wizard_logo.svg                white mark
  overlay/common/theme/universal/wizard_logo_dark.svg           red mark
  overlay/common/theme/universal/wizard_footer_logo.svg         red mark
  overlay/common/theme/{colored,dark,black,white}/state-*.svg   tray states

Run via scripts/gen-icons.sh (bootstraps a Pillow venv). Derived assets are
committed; regenerate here after a brand change, never hand-edit the output.

Known limitation, recorded in MAINTAINING.md: the brand master embeds
188px raster layers, so the 512/1024 renders are lanczos upscales and are
slightly soft. A true vector master in meta/brand would fix all sizes at
once - regenerate when one lands.
"""

import base64
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parent.parent
BRAND = REPO.parent / "meta" / "brand" / "logo.svg"

RED = (0xB8, 0x08, 0x18, 255)  # brand red-600
SIZES = [16, 24, 32, 48, 64, 128, 256, 512, 1024]
SIDEBAR_SIZES = [16, 32, 64, 128, 256, 512, 1024]


def load_mark() -> Image.Image:
    """Compose the two embedded PNG layers exactly as logo.svg positions them.

    logo.svg: canvas 197x197; layer0 at (4,22) 188x152; layer1 at (57,86)
    82x50. Parsed from the SVG so a re-exported master keeps working as long
    as it stays in the same shape.
    """
    svg = BRAND.read_text()
    layers = []
    for m in re.finditer(
        r'<image x="(\d+)" y="(\d+)" width="(\d+)" height="(\d+)" '
        r'xlink:href="data:img/png;base64,([^"]+)"', svg):
        x, y, w, h = (int(m.group(i)) for i in range(1, 5))
        raw = base64.b64decode(m.group(5))
        img = Image.open(__import__("io").BytesIO(raw)).convert("RGBA")
        layers.append((x, y, w, h, img))
    if not layers:
        sys.exit(f"no embedded PNG layers found in {BRAND}")
    side = int(re.search(r'viewBox="0 0 (\d+) (\d+)"', svg).group(1))
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    for x, y, w, h, img in layers:
        if img.size != (w, h):
            img = img.resize((w, h), Image.LANCZOS)
        canvas.alpha_composite(img, (x, y))
    # trim transparent border so scaling is about the mark, not the canvas
    return canvas.crop(canvas.getbbox())


def recolor(img: Image.Image, rgba) -> Image.Image:
    """Repaint every non-transparent pixel with one colour, keeping alpha."""
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    solid = Image.new("RGBA", img.size, rgba)
    out.paste(solid, (0, 0), img.getchannel("A"))
    return out


def rounded_tile(size: int, fill) -> Image.Image:
    """White (or given) rounded-square tile drawn at 4x and downsampled."""
    ss = size * 4
    tile = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(tile)
    d.rounded_rectangle([0, 0, ss - 1, ss - 1], radius=int(ss * 0.22), fill=fill)
    return tile.resize((size, size), Image.LANCZOS)


def alpha_gain(img: Image.Image, gain: float) -> Image.Image:
    """Boost alpha so thin strokes survive small-size downscaling."""
    a = img.getchannel("A").point(lambda v: min(255, int(v * gain)))
    out = img.copy()
    out.putalpha(a)
    return out


def app_icon(mark: Image.Image, size: int, badge: bool) -> Image.Image:
    icon = rounded_tile(size, (255, 255, 255, 255))
    inner = int(size * (0.86 if size <= 48 else 0.72))
    scale = inner / max(mark.size)
    mw, mh = (max(1, round(d * scale)) for d in mark.size)
    m = mark.resize((mw, mh), Image.LANCZOS)
    if size <= 48:
        m = alpha_gain(m, 2.2)
    icon.alpha_composite(m, ((size - mw) // 2, (size - mh) // 2))
    if badge:
        stg_badge(icon, size)
    return icon


def stg_badge(icon: Image.Image, size: int) -> None:
    """Visible STG corner badge on the staging icon (brand rule)."""
    ss = size * 4
    layer = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    bw, bh = int(ss * 0.44), int(ss * 0.20)
    x0, y0 = ss - bw, ss - bh
    d.rounded_rectangle([x0, y0, ss - 1, ss - 1], radius=int(bh * 0.30), fill=RED)
    try:
        font = ImageFont.load_default(size=int(bh * 0.62))
    except TypeError:  # Pillow < 10.1
        font = ImageFont.load_default()
    tb = d.textbbox((0, 0), "STG", font=font)
    tw, th = tb[2] - tb[0], tb[3] - tb[1]
    d.text((x0 + (bw - tw) / 2 - tb[0], y0 + (bh - th) / 2 - tb[1]), "STG",
           font=font, fill=(255, 255, 255, 255))
    icon.alpha_composite(layer.resize(icon.size, Image.LANCZOS))


def sidebar_icon(mark: Image.Image, size: int) -> Image.Image:
    """macOS sidebar wants a monochrome template-style glyph."""
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    inner = int(size * 0.92)
    scale = inner / max(mark.size)
    mw, mh = (max(1, round(d * scale)) for d in mark.size)
    m = recolor(mark.resize((mw, mh), Image.LANCZOS), (35, 38, 47, 255))
    icon.alpha_composite(m, ((size - mw) // 2, (size - mh) // 2))
    return icon


def png_as_svg(img: Image.Image) -> str:
    """Wrap a raster render in an SVG, the same shape as the brand master."""
    import io
    buf = io.BytesIO()
    img.save(buf, "PNG")
    b64 = base64.b64encode(buf.getvalue()).decode()
    w, h = img.size
    return (f'<svg xmlns="http://www.w3.org/2000/svg" '
            f'xmlns:xlink="http://www.w3.org/1999/xlink" width="{w}" '
            f'height="{h}" viewBox="0 0 {w} {h}">\n'
            f'  <image x="0" y="0" width="{w}" height="{h}" '
            f'xlink:href="data:image/png;base64,{b64}"/>\n</svg>\n')


# --- tray state icons (hand-authored geometry, recoloured per tray theme) ---

STATE_COLORS = {  # "colored" theme: estate palette
    "ok": "#2e7d32",
    "error": "#b80818",
    "information": "#1565c0",
    "offline": "#64748b",
    "pause": "#b45309",
    "sync": "#0e7490",
}

GLYPHS = {  # white glyphs drawn inside a filled circle, 32x32 viewBox
    "ok": '<path d="M9.5 16.5l4.5 4.5 8.5-9" fill="none" stroke="{fg}" '
          'stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round"/>',
    "error": '<path d="M11 11l10 10M21 11l-10 10" fill="none" stroke="{fg}" '
             'stroke-width="3.4" stroke-linecap="round"/>',
    "information": '<circle cx="16" cy="10" r="2.1" fill="{fg}"/>'
                   '<path d="M16 14.6v8" fill="none" stroke="{fg}" '
                   'stroke-width="3.4" stroke-linecap="round"/>',
    "offline": '<path d="M10 22a6 6 0 1 1 1.2-11.9 7 7 0 0 1 13.3 2A4.5 4.5 '
               '0 0 1 23 22z" fill="none" stroke="{fg}" stroke-width="2.6"/>'
               '<path d="M8 25L25 8" fill="none" stroke="{fg}" '
               'stroke-width="3" stroke-linecap="round"/>',
    "pause": '<path d="M12.5 10.5v11M19.5 10.5v11" fill="none" stroke="{fg}" '
             'stroke-width="3.4" stroke-linecap="round"/>',
    "sync": '<path d="M22.5 12.5a7.5 7.5 0 0 0-13-1.5M9.5 19.5a7.5 7.5 0 0 0 '
            '13 1.5" fill="none" stroke="{fg}" stroke-width="3" '
            'stroke-linecap="round"/>'
            '<path d="M9 7v4.5h4.5M23 25v-4.5h-4.5" fill="none" stroke="{fg}" '
            'stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>',
}


def state_svg(state: str, theme: str) -> str:
    if theme == "colored":
        bg, fg = STATE_COLORS[state], "#ffffff"
    elif theme == "dark":  # for dark trays: light glyph on subtle disc
        bg, fg = "#e2e8f0", "#0f172a"
    elif theme == "black":
        bg, fg = "#000000", "#ffffff"
    else:  # white
        bg, fg = "#ffffff", "#000000"
    glyph = GLYPHS[state].format(fg=fg)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" '
            'viewBox="0 0 32 32">\n'
            f'  <circle cx="16" cy="16" r="15" fill="{bg}"/>\n'
            f'  {glyph}\n</svg>\n')


def main() -> None:
    mark = load_mark()
    envs = {
        "production": ("aitydrive", False),
        "staging": ("aitydrive-staging", True),
    }
    for env, (icon_name, badge) in envs.items():
        colored = REPO / "overlay" / env / "theme" / "colored"
        universal = REPO / "overlay" / env / "theme" / "universal"
        colored.mkdir(parents=True, exist_ok=True)
        universal.mkdir(parents=True, exist_ok=True)
        for n in SIZES:
            app_icon(mark, n, badge).save(colored / f"{n}-{icon_name}-icon.png")
        for n in SIDEBAR_SIZES:
            sidebar_icon(mark, n).save(colored / f"{n}-{icon_name}-sidebar.png")
        (universal / f"{icon_name}-icon.svg").write_text(
            png_as_svg(app_icon(mark, 512, badge)))

    uni = REPO / "overlay" / "common" / "theme" / "universal"
    uni.mkdir(parents=True, exist_ok=True)
    white_mark = recolor(mark, (255, 255, 255, 255))
    (uni / "wizard_logo.svg").write_text(png_as_svg(white_mark))
    (uni / "wizard_logo_dark.svg").write_text(png_as_svg(mark))
    (uni / "wizard_footer_logo.svg").write_text(
        png_as_svg(mark.resize((mark.width // 2, mark.height // 2), Image.LANCZOS)))

    for theme in ("colored", "dark", "black", "white"):
        d = REPO / "overlay" / "common" / "theme" / theme
        d.mkdir(parents=True, exist_ok=True)
        for state in GLYPHS:
            (d / f"state-{state}.svg").write_text(state_svg(state, theme))

    print("icon set regenerated under overlay/")


if __name__ == "__main__":
    main()
