#!/usr/bin/env python3
"""Draws five concept icons for Poe — a cartoony lantern, tipped on its side.

Pure SVG, no dependencies. Writes assets/icon-concepts/*.svg; render them to
PNG with any SVG rasteriser (the build used a ten-line AppKit script).

    python3 tools/make_icon_concepts.py
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "icon-concepts")
INK = "#1B1035"


def lantern(p, *, metal="url(#metal)", glass="url(#glass)", outline=INK, width=14,
            flame_outer="#FFB347", flame_core="#FFF4C2", face=None, sticker=None, tilt=0):
    """One lantern, upright, centred near the origin (y grows downward).

    `tilt` is how far the lantern has been tipped: the flame turns back by the
    same amount, because a fallen lantern's flame still burns upward."""
    def body(stroke, sw, fill_metal, fill_glass, inner=True):
        s = f'stroke="{stroke}" stroke-width="{sw}" stroke-linejoin="round" stroke-linecap="round"'
        parts = [
            # handle ring and knob
            f'<circle cx="0" cy="-252" r="44" fill="none" {s}/>',
            f'<circle cx="0" cy="-252" r="44" fill="none" stroke="{fill_metal}" stroke-width="{max(sw-12, 0)}"/>' if inner else "",
            f'<rect x="-24" y="-232" width="48" height="32" rx="10" fill="{fill_metal}" {s}/>',
            # cap
            f'<path d="M -72 -205 L 72 -205 Q 88 -205 98 -192 L 132 -150 L -132 -150 L -98 -192 Q -88 -205 -72 -205 Z" fill="{fill_metal}" {s}/>',
            # glass
            f'<rect x="-106" y="-150" width="212" height="252" rx="34" fill="{fill_glass}" {s}/>',
        ]
        if inner:
            parts += [
                # flame, kept upright however the lantern lies
                f'<g transform="rotate({-tilt} 0 -27)">'
                f'<path d="M 0 -100 C 46 -42 62 4 0 46 C -62 4 -46 -42 0 -100 Z" fill="{flame_outer}" stroke="{outline}" stroke-width="{sw*0.55}" stroke-linejoin="round"/>',
                f'<path d="M 0 -58 C 24 -24 32 2 0 26 C -32 2 -24 -24 0 -58 Z" fill="{flame_core}"/>',
                face or "",
                '</g>',
                # glass bars and a glint
                f'<path d="M -38 -150 L -38 102 M 38 -150 L 38 102" stroke="{outline}" stroke-width="{sw*0.6}" opacity="0.55"/>',
                '<path d="M -82 -120 Q -88 -40 -82 20" stroke="#FFFFFF" stroke-width="12" stroke-linecap="round" fill="none" opacity="0.55"/>',
            ]
        parts += [
            # base and foot
            f'<rect x="-138" y="100" width="276" height="62" rx="24" fill="{fill_metal}" {s}/>',
            f'<rect x="-112" y="160" width="224" height="28" rx="12" fill="{fill_metal}" {s}/>',
        ]
        if inner:
            parts.append('<path d="M -112 116 L 96 116" stroke="#FFFFFF" stroke-width="10" stroke-linecap="round" opacity="0.35"/>')
        return "".join(parts)

    out = ""
    if sticker:
        out += body(sticker, width + 44, sticker, sticker, inner=False)
    out += body(outline, width, metal, glass)
    return f'<g transform="{p}">{out}</g>'


def place(cx, cy, angle, scale=1.0):
    # Pivot about the lantern's middle, which sits at y = -55 in its own space.
    return f"translate({cx} {cy}) rotate({angle}) scale({scale}) translate(0 55)"


def plate(fill, rim="#FFFFFF"):
    """The macOS icon tile, with a soft stacked shadow beneath it."""
    shadow = "".join(
        f'<rect x="{100 - i*3}" y="{108 + i*2}" width="{824 + i*6}" height="{824 + i*6}" rx="{186 + i*3}" fill="#000" opacity="0.06"/>'
        for i in range(6)
    )
    return (shadow +
            f'<rect x="100" y="100" width="824" height="824" rx="186" fill="{fill}"/>'
            f'<rect x="102" y="102" width="820" height="820" rx="184" fill="none" stroke="{rim}" stroke-opacity="0.10" stroke-width="3"/>')


def svg(defs, body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            f'<defs>{defs}<clipPath id="tile"><rect x="100" y="100" width="824" height="824" rx="186"/></clipPath></defs>'
            f'{body}</svg>')


def lin(id, stops, x2=0, y2=1):
    s = "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in stops)
    return f'<linearGradient id="{id}" x1="0" y1="0" x2="{x2}" y2="{y2}">{s}</linearGradient>'


def rad(id, stops, cx=0.5, cy=0.5, r=0.5):
    s = "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for o, c, a in stops)
    return f'<radialGradient id="{id}" cx="{cx}" cy="{cy}" r="{r}">{s}</radialGradient>'


def stars(points, color="#FFFFFF"):
    return "".join(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{color}" opacity="{o}"/>' for x, y, r, o in points)


STARS = [(250, 260, 5, .7), (330, 205, 3, .5), (760, 240, 4, .6), (690, 320, 2.5, .45),
         (820, 400, 3, .5), (215, 420, 2.5, .4), (560, 190, 3, .45)]


# 1 — Brass, tipped over: the classic lantern knocked onto its side, its
#     amber light spilling across the floor.
def brass():
    defs = (lin("bg", [(0, "#3A2370", 1), (1, "#0E0B1F", 1)])
            + lin("metal", [(0, "#FFD978", 1), (0.55, "#E3A23F", 1), (1, "#A8641F", 1)], x2=1, y2=0)
            + rad("glass", [(0, "#FFF6CF", 1), (0.6, "#FFC45C", 1), (1, "#F08A2E", 1)])
            + rad("halo", [(0, "#FFC45C", .55), (0.5, "#FF9E3D", .18), (1, "#FF9E3D", 0)])
            + rad("pool", [(0, "#FFD27A", .6), (1, "#FFB347", 0)]))
    body = (plate("url(#bg)") + '<g clip-path="url(#tile)">'
            + stars(STARS)
            + '<rect x="100" y="700" width="824" height="230" fill="#0A0818" opacity="0.55"/>'
            + '<circle cx="520" cy="560" r="330" fill="url(#halo)"/>'
            + '<ellipse cx="560" cy="712" rx="330" ry="58" fill="url(#pool)"/>'
            + '<ellipse cx="470" cy="716" rx="250" ry="26" fill="#000" opacity="0.35"/>'
            + lantern(place(480, 590, 84), tilt=84)
            + '</g>')
    return svg(defs, body)


# 2 — Cyan spirit: a round little character of a lantern, leaning over with
#     a sleepy-happy flame that has a face.
def spirit():
    face = ('<circle cx="-15" cy="2" r="7" fill="#1B1035"/><circle cx="15" cy="2" r="7" fill="#1B1035"/>'
            '<path d="M -10 18 Q 0 27 10 18" stroke="#1B1035" stroke-width="5" fill="none" stroke-linecap="round"/>'
            '<ellipse cx="-27" cy="16" rx="7" ry="4" fill="#FF8FB1" opacity="0.8"/>'
            '<ellipse cx="27" cy="16" rx="7" ry="4" fill="#FF8FB1" opacity="0.8"/>')
    defs = (lin("bg", [(0, "#4A4FC4", 1), (1, "#15173A", 1)])
            + lin("metal", [(0, "#D4C6FF", 1), (0.6, "#9B82F5", 1), (1, "#6A4FD6", 1)], x2=1, y2=0)
            + rad("glass", [(0, "#F2FFFF", 1), (0.55, "#8FF1F7", 1), (1, "#33B9CF", 1)])
            + rad("halo", [(0, "#5FE6F0", .55), (0.55, "#5FE6F0", .12), (1, "#5FE6F0", 0)]))
    body = (plate("url(#bg)") + '<g clip-path="url(#tile)">'
            + stars(STARS, "#CFFAFF")
            + '<path d="M 100 760 Q 512 650 924 760 L 924 930 L 100 930 Z" fill="#0F1030" opacity="0.7"/>'
            + '<circle cx="512" cy="520" r="340" fill="url(#halo)"/>'
            + '<ellipse cx="540" cy="745" rx="200" ry="24" fill="#000" opacity="0.35"/>'
            + lantern(place(512, 530, 34, 0.98), tilt=34, flame_outer="#FFE58A", flame_core="#FFFFFF", face=face)
            + '</g>')
    return svg(defs, body)


# 3 — Light becomes a page: the lantern lies on its side and its beam opens
#     out into a sheet of paper — light, then words.
def page():
    lines = "".join(f'<path d="M -120 {y} L {w} {y}" stroke="#7B8CFF" stroke-width="10" stroke-linecap="round" opacity="0.55"/>'
                    for y, w in [(-90, 110), (-45, 120), (0, 80), (45, 115), (90, 40)])
    defs = (lin("bg", [(0, "#1D2250", 1), (1, "#0B0D14", 1)])
            + lin("metal", [(0, "#C9BBFF", 1), (0.6, "#8C74F0", 1), (1, "#5B43C7", 1)], x2=1, y2=0)
            + rad("glass", [(0, "#F2FFFF", 1), (0.6, "#8FF1F7", 1), (1, "#3CC2D6", 1)])
            + lin("beam", [(0, "#8FF1F7", .75), (1, "#A78BFA", .08)], x2=1, y2=0)
            + rad("halo", [(0, "#5FE6F0", .5), (1, "#5FE6F0", 0)]))
    body = (plate("url(#bg)") + '<g clip-path="url(#tile)">'
            + stars(STARS)
            + '<circle cx="380" cy="600" r="250" fill="url(#halo)"/>'
            + '<path d="M 420 520 L 760 330 L 840 720 L 420 690 Z" fill="url(#beam)"/>'
            + f'<g transform="translate(690 470) rotate(9)">'
              '<rect x="-150" y="-180" width="300" height="360" rx="26" fill="#F7F5FF" stroke="#1B1035" stroke-width="12" stroke-linejoin="round"/>'
              '<path d="M 90 -180 L 150 -120 L 90 -120 Z" fill="#D9D3FF" stroke="#1B1035" stroke-width="10" stroke-linejoin="round"/>'
              f'{lines}</g>'
            + '<ellipse cx="350" cy="760" rx="210" ry="24" fill="#000" opacity="0.4"/>'
            + lantern(place(345, 640, 96, 0.66), tilt=96)
            + '</g>')
    return svg(defs, body)


# 4 — Flat sticker: bold, flat shapes in Poe's own gradient, with a white
#     die-cut edge, like a laptop sticker.
def sticker():
    defs = (lin("bg", [(0, "#5FE6F0", 1), (0.5, "#7B8CFF", 1), (1, "#A78BFA", 1)], x2=1, y2=1)
            + rad("halo", [(0, "#FFFFFF", .5), (1, "#FFFFFF", 0)]))
    body = (plate("url(#bg)") + '<g clip-path="url(#tile)">'
            + '<circle cx="512" cy="520" r="300" fill="url(#halo)"/>'
            + '<ellipse cx="520" cy="745" rx="260" ry="30" fill="#1B1035" opacity="0.25"/>'
            + lantern(place(512, 560, 72, 0.98), tilt=72, metal="#2B1E5C", glass="#FFE8A3", outline=INK,
                      flame_outer="#FF9F43", flame_core="#FFFFFF", sticker="#FFFFFF")
            + '</g>')
    return svg(defs, body)


# 5 — Resting on notebooks: a lantern that's done for the night, lying on a
#     stack of notebooks, eyes closed, still glowing.
def notebooks():
    face = ('<path d="M -24 0 Q -15 9 -6 0 M 6 0 Q 15 9 24 0" stroke="#1B1035" stroke-width="5" fill="none" stroke-linecap="round"/>'
            '<ellipse cx="0" cy="20" rx="6" ry="4" fill="#1B1035"/>')

    def book(y, w, color, spine):
        return (f'<rect x="{512 - w/2}" y="{y}" width="{w}" height="62" rx="16" fill="{color}" stroke="{INK}" stroke-width="12" stroke-linejoin="round"/>'
                f'<rect x="{512 - w/2 + 26}" y="{y + 14}" width="{w - 70}" height="34" rx="8" fill="#FBF8FF"/>'
                f'<path d="M {512 - w/2 + 36} {y + 26} L {512 + w/2 - 54} {y + 26} M {512 - w/2 + 36} {y + 37} L {512 + w/2 - 54} {y + 37}" stroke="#C9C2E8" stroke-width="3"/>'
                f'<rect x="{512 + w/2 - 40}" y="{y}" width="24" height="62" fill="{spine}"/>'
                f'<rect x="{512 - w/2}" y="{y}" width="{w}" height="62" rx="16" fill="none" stroke="{INK}" stroke-width="12"/>')
    defs = (lin("bg", [(0, "#3B2268", 1), (1, "#120C24", 1)])
            + lin("metal", [(0, "#FFD978", 1), (0.55, "#E3A23F", 1), (1, "#A8641F", 1)], x2=1, y2=0)
            + rad("glass", [(0, "#FFF6CF", 1), (0.6, "#FFC45C", 1), (1, "#F08A2E", 1)])
            + rad("halo", [(0, "#FFC45C", .45), (0.5, "#5FE6F0", .12), (1, "#5FE6F0", 0)]))
    body = (plate("url(#bg)") + '<g clip-path="url(#tile)">'
            + stars(STARS)
            + '<circle cx="512" cy="430" r="340" fill="url(#halo)"/>'
            + '<ellipse cx="512" cy="826" rx="290" ry="26" fill="#000" opacity="0.4"/>'
            + book(756, 500, "#7B8CFF", "#5A69E0")
            + book(694, 460, "#5FE6F0", "#36BACB")
            + book(632, 480, "#A78BFA", "#8566E8")
            + lantern(place(512, 486, 90, 0.86), tilt=90, flame_outer="#FFB347", flame_core="#FFF4C2", face=face)
            + '</g>')
    return svg(defs, body)


CONCEPTS = {
    "1-brass-tipped-over": brass,
    "2-cyan-spirit": spirit,
    "3-light-becomes-a-page": page,
    "4-flat-sticker": sticker,
    "5-asleep-on-notebooks": notebooks,
}

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, draw in CONCEPTS.items():
        path = os.path.join(OUT, f"poe-icon-{name}.svg")
        with open(path, "w") as f:
            f.write(draw())
        print(path)
