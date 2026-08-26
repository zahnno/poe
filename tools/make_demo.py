#!/usr/bin/env python3
"""Writes assets/demo.svg — a looping, self-contained demo of Poe.

No dependencies, no video encoder, nothing to install: the whole demo is one
SVG that animates itself, so GitHub renders it inline and it stays a few tens
of kilobytes. Every animation runs the full 28s of the timeline and repeats
indefinitely, with the scene timing encoded in keyTimes, so the loop restarts
in perfect sync rather than drifting the way per-element `begin` offsets do.

    python3 tools/make_demo.py
"""

from pathlib import Path

TOTAL = 28.0                     # one full pass of the timeline, in seconds
W, H = 1280, 820                 # the frame
WX, WY, WW, WH = 100, 76, 1080, 620   # the window inside it
SB = 268                         # sidebar width, same as SidebarView
EX, EW = WX + SB, WW - SB        # the editor pane

# Theme.swift, converted once.
VOID   = "#08090E"
INK    = "#E5E9F5"
INKDIM = "#98A0B6"
INKFNT = "#666F87"
ACCENT = "#5FE6F0"
DEEP   = "#7B8CFF"
VIOLET = "#A78BFA"
ROSE   = "#F472B6"
LANT   = "#FFB425"
FLAME  = "#FFF6CF"
FRAME  = "#9F876C"
FRAMED = "#5D4C3D"

MONO  = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, monospace"
ROUND = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Helvetica Neue', Helvetica, Arial, sans-serif"

out = []          # the document body
defs = []         # anything that has to live in <defs>
_uid = [0]


def uid(prefix):
    _uid[0] += 1
    return f"{prefix}{_uid[0]}"


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;"))


# ── the timeline ────────────────────────────────────────────────────────────

def anim(attr, frames, calc="linear", extra=""):
    """One attribute, keyframed across the whole 28s and looped.

    `frames` is [(seconds, value), ...]; it is clamped to [0, TOTAL] and made
    monotonic, because SMIL silently drops an animation whose keyTimes step
    backwards and the failure looks like "that element just never moves".
    """
    pts, last = [], -1.0
    for t, v in frames:
        t = max(0.0, min(TOTAL, float(t)))
        if t < last:
            t = last
        if pts and abs(t - pts[-1][0]) < 1e-6:
            pts[-1] = (t, v)          # same instant: the later value wins
        else:
            pts.append((t, v))
        last = t
    if pts[0][0] > 0:
        pts.insert(0, (0.0, pts[0][1]))
    if pts[-1][0] < TOTAL:
        pts.append((TOTAL, pts[-1][1]))
    times = ";".join(f"{t / TOTAL:.6f}" for t, _ in pts)
    values = ";".join(str(v) for _, v in pts)
    return (f'<animate attributeName="{attr}" values="{values}" keyTimes="{times}" '
            f'dur="{TOTAL}s" calcMode="{calc}" repeatCount="indefinite" {extra}/>')


def gate(windows, fade=0.32):
    """Opacity keyframes that show a group only during the given windows."""
    if isinstance(windows, tuple):
        windows = [windows]
    frames = [(0.0, 1 if windows[0][0] <= 0 else 0)]
    for a, b in windows:
        if a > 0:
            frames += [(a, 0), (a + fade, 1)]
        else:
            frames += [(0.0, 1)]
        frames += [(max(b - fade, a + fade), 1), (b, 0)]
    return anim("opacity", frames)


def scene(windows, body, fade=0.32, transform=None):
    t = f' transform="{transform}"' if transform else ""
    out.append(f'<g{t} opacity="0">{gate(windows, fade)}{body}</g>')


# ── text ────────────────────────────────────────────────────────────────────

class Span:
    """A run of characters with a known advance width, so the typing reveal
    and the caret can be placed by arithmetic instead of by guesswork."""

    def __init__(self, text, fill=INK, size=15.0, cw=9.0, family=MONO,
                 weight="400", style="normal", opacity=1.0, letter=0.0):
        self.text, self.fill, self.size, self.cw = text, fill, size, cw
        self.family, self.weight, self.style = family, weight, style
        self.opacity, self.letter = opacity, letter

    def svg(self, x, y):
        extra = ""
        if self.opacity < 1:
            extra += f' opacity="{self.opacity}"'
        if self.style != "normal":
            extra += f' font-style="{self.style}"'
        if self.letter:
            extra += f' letter-spacing="{self.letter}"'
        length = len(self.text) * self.cw
        return (f'<text x="{x:.1f}" y="{y:.1f}" font-family="{self.family}" '
                f'font-size="{self.size}" font-weight="{self.weight}" fill="{self.fill}"'
                f' textLength="{length:.1f}" lengthAdjust="spacing"{extra}'
                f' xml:space="preserve">{esc(self.text)}</text>')


def mono(text, fill=INK, weight="400", opacity=1.0, size=15.0, style="normal"):
    return Span(text, fill, size, size * 0.6, MONO, weight, style, opacity)


def lay(x0, spans):
    """Place spans left to right; return their svg, the x after each character
    (index 0 = before the first), and the end x."""
    body, x, stops = [], x0, [x0]
    for s in spans:
        body.append((x, s))
        for i in range(len(s.text)):
            stops.append(x + (i + 1) * s.cw)
        x += len(s.text) * s.cw
    return body, stops, x


def text(text_, x, y, size=13, fill=INK, family=ROUND, weight="400",
         anchor="start", opacity=1.0, extra=""):
    a = f' text-anchor="{anchor}"' if anchor != "start" else ""
    o = f' opacity="{opacity}"' if opacity < 1 else ""
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-family="{family}" font-size="{size}" '
            f'font-weight="{weight}" fill="{fill}"{a}{o}{extra} '
            f'xml:space="preserve">{esc(text_)}</text>')


def rect(x, y, w, h, r=0, fill="none", stroke=None, sw=1, extra=""):
    s = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
    return (f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" '
            f'rx="{r}" fill="{fill}"{s}{extra}/>')


# ── the document being written ──────────────────────────────────────────────
# Markers ('#', '**', '- [x]') stay in the text and merely dim, which is the
# whole trick the editor plays: it restyles, it never rewrites.

DOC = [
    [mono("# ", INKFNT, opacity=0.8),
     Span("Poe", ACCENT, 22, 12.4, ROUND, "600")],
    [],
    [mono("A quiet place to think. Your notes never")],
    [mono("leave this machine — every note lives in")],
    [mono("**", INKFNT, opacity=0.75), mono("one JSON file", INK, "700"),
     mono("**", INKFNT, opacity=0.75), mono(" you can read.")],
    [],
    [mono("- ", INKFNT, opacity=0.8), mono("[x] ", VIOLET, "700"),
     mono("a note styles itself as you type", INKDIM)],
    [mono("- ", INKFNT, opacity=0.8), mono("[ ] ", INKFNT),
     mono("saving — it does that on its own")],
    [],
    [mono("> ", VIOLET, opacity=0.8),
     mono("“Deep into that darkness peering…”", INKDIM, style="italic")],
]

TX, TY, LH = EX + 34, WY + 96, 27          # text origin and line height
TS, TE = 3.5, 9.7                          # when the typing runs


def doc_lines(doc=DOC, x0=TX, y0=TY):
    """Lay every line out once; everything downstream indexes into this."""
    laid = []
    for i, spans in enumerate(doc):
        body, stops, end = lay(x0, spans)
        laid.append({"y": y0 + i * LH, "body": body, "stops": stops, "end": end})
    return laid


def render_doc(laid, upto=None):
    return "".join(s.svg(x, ln["y"])
                   for ln in laid[:upto]
                   for x, s in ln["body"])


def typing(laid):
    """The reveal: a clip rect per line whose width steps a character at a time,
    plus a caret that walks the same steps."""
    # Weight a line break like a few characters so the pauses land naturally.
    beats = []
    for i, ln in enumerate(laid):
        n = len(ln["stops"]) - 1
        for k in range(1, n + 1):
            beats.append((i, k, 1.0))
        beats.append((i, n, 4.0))
    span_total = sum(w for _, _, w in beats)
    step, clock = (TE - TS) / span_total, TS
    times = []
    for i, k, w in beats:
        clock += (TE - TS) * (w / span_total)
        times.append((clock, i, k))

    body, caret = [], [(0.0, laid[0]["stops"][0]), (TS, laid[0]["stops"][0])]
    caret_y = [(0.0, laid[0]["y"] - 15), (TS, laid[0]["y"] - 15)]
    for i, ln in enumerate(laid):
        cid = uid("type")
        frames = [(0.0, 0.0), (TS, 0.0)]
        for t, li, k in times:
            if li == i:
                frames.append((t, round(ln["stops"][k] - ln["stops"][0] + 2, 1)))
        frames.append((TE, round(ln["end"] - ln["stops"][0] + 2, 1)))
        defs.append(f'<clipPath id="{cid}">'
                    f'<rect x="{ln["stops"][0] - 2:.1f}" y="{ln["y"] - 22:.1f}" '
                    f'width="0" height="30">{anim("width", frames, "discrete")}</rect>'
                    f'</clipPath>')
        body.append(f'<g clip-path="url(#{cid})">'
                    + "".join(s.svg(x, ln["y"]) for x, s in ln["body"]) + '</g>')

    for t, li, k in times:
        caret.append((t, round(laid[li]["stops"][k], 1)))
        caret_y.append((t, round(laid[li]["y"] - 15, 1)))
    caret.append((TE, round(laid[-1]["end"], 1)))
    caret_y.append((TE, round(laid[-1]["y"] - 15, 1)))

    body.append(
        f'<g><rect x="0" y="0" width="2" height="20" rx="1" fill="{ACCENT}" '
        f'filter="url(#caretGlow)">'
        + anim("x", caret, "discrete") + anim("y", caret_y, "discrete")
        + f'<animate attributeName="opacity" values="1;1;0.15;1" dur="1.05s" '
        f'repeatCount="indefinite"/></rect></g>')
    return "".join(body)


# ── pieces of chrome ────────────────────────────────────────────────────────

def lantern(x, y, height, glow=True):
    s = height / 140.0
    halo = (f'<ellipse cx="50" cy="78" rx="24" ry="30" fill="{LANT}" opacity="0.45" '
            f'filter="url(#halo)"><animate attributeName="opacity" '
            f'values="0.36;0.54;0.42;0.5;0.36" dur="6s" repeatCount="indefinite"/>'
            f'</ellipse>') if glow else ""
    return f'''<g transform="translate({x:.1f},{y:.1f}) scale({s:.4f})">
  {halo}
  <path d="M37,55 C30,68 30,82 37,95 L63,95 C70,82 70,68 63,55 Z" fill="url(#glassGlow)"/>
  <path d="M50,72 C57,81 55,89 50,89 C45,89 43,81 50,72 Z" fill="url(#flameGrad)">
    <animate attributeName="opacity" values="1;0.86;1;0.93;1" dur="4.5s" repeatCount="indefinite"/>
  </path>
  <g clip-path="url(#glassClip)" stroke="{FRAMED}" stroke-width="2.6" fill="none">
    <path d="M35,63 L65,87"/><path d="M65,63 L35,87"/><path d="M34,89 L66,89"/>
  </g>
  <g stroke="{FRAMED}" stroke-width="3.2" fill="none">
    <path d="M28,31 C19,52 19,84 28,103"/><path d="M72,31 C81,52 81,84 72,103"/>
  </g>
  <rect x="19" y="30" width="9" height="3" rx="1.2" fill="{FRAME}"/>
  <rect x="72" y="30" width="9" height="3" rx="1.2" fill="{FRAME}"/>
  <path d="M43.03,13.61 A7,7 0 0 1 56.97,13.61" stroke="{FRAME}" stroke-width="3" fill="none"/>
  <path d="M35,19 L65,19 L71,26 L29,26 Z" fill="{FRAME}"/>
  <rect x="37" y="26" width="26" height="6" rx="2.4" fill="{FRAMED}"/>
  <rect x="35" y="32" width="30" height="6" rx="2.4" fill="{FRAME}"/>
  <rect x="39" y="38" width="22" height="9" rx="3.6" fill="{FRAMED}"/>
  <g fill="{VOID}" opacity="0.75"><circle cx="43" cy="42.9" r="1.4"/>
    <circle cx="50" cy="42.9" r="1.4"/><circle cx="57" cy="42.9" r="1.4"/></g>
  <path d="M37,47 L63,47 L69,56 L31,56 Z" fill="url(#skirtGrad)"/>
  <rect x="33" y="93" width="34" height="7" rx="2.8" fill="{FRAME}"/>
  <path d="M34,100 L66,100 L63,114 L37,114 Z" fill="url(#fountGrad)"/>
  <rect x="45" y="96" width="10" height="7" rx="2.8" fill="{FRAMED}"/>
  <path d="M35,114 L65,114 L68,128 L32,128 Z" fill="{FRAME}"/>
  <rect x="30" y="128" width="40" height="5" rx="2" fill="{FRAMED}"/>
</g>'''


def icon(name, cx, cy, colour=INKDIM, size=15):
    """Small stand-ins for the SF Symbols the toolbar actually uses."""
    k = size / 16.0
    g = f'<g transform="translate({cx:.1f},{cy:.1f}) scale({k:.3f})" fill="none" ' \
        f'stroke="{colour}" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">'
    if name == "sidebar":
        p = ('<rect x="-8" y="-6" width="16" height="12" rx="2.5"/>'
             '<path d="M-2.5,-6 L-2.5,6"/>'
             f'<rect x="-8" y="-6" width="5.5" height="12" rx="2.5" fill="{colour}" '
             'stroke="none" opacity="0.55"/>')
    elif name == "pin":
        p = (f'<path d="M-3.5,-6 L3.5,-6 L2,-1 L5,1.5 L-5,1.5 L-2,-1 Z" fill="{colour}" '
             'stroke="none"/><path d="M0,1.5 L0,6.5"/>')
    elif name == "search":
        p = '<circle cx="-1" cy="-1" r="5"/><path d="M2.8,2.8 L7,7"/>'
    elif name == "eye":
        p = ('<path d="M-8,0 C-5,-5 5,-5 8,0 C5,5 -5,5 -8,0 Z"/>'
             f'<circle cx="0" cy="0" r="2.1" fill="{colour}" stroke="none"/>')
    elif name == "pencil":
        p = ('<path d="M-6.5,6.5 L-5.5,2.5 L2.5,-5.5 L5.5,-2.5 L-2.5,5.5 Z"/>'
             '<path d="M2.5,-5.5 L5.5,-2.5"/>')
    elif name == "dots":
        p = f'<g fill="{colour}" stroke="none"><circle cx="-5" cy="0" r="1.6"/>' \
            '<circle cx="0" cy="0" r="1.6"/><circle cx="5" cy="0" r="1.6"/></g>'
    elif name == "plus":
        p = '<path d="M0,-5.5 L0,5.5"/><path d="M-5.5,0 L5.5,0"/>'
    elif name == "chevup":
        p = '<path d="M-3.5,1.8 L0,-1.8 L3.5,1.8"/>'
    elif name == "chevdown":
        p = '<path d="M-3.5,-1.8 L0,1.8 L3.5,-1.8"/>'
    elif name == "doc":
        p = ('<path d="M-5,-7 L2,-7 L5.5,-3.5 L5.5,7 L-5,7 Z"/>'
             '<path d="M2,-7 L2,-3.5 L5.5,-3.5"/>')
    elif name == "docdown":
        p = ('<path d="M-6,-7 L1,-7 L6,-2 L6,3"/><path d="M-6,-7 L-6,7 L6,7 L6,3"/>'
             '<path d="M0,-2.5 L0,3.5"/><path d="M-3,0.8 L0,3.8 L3,0.8"/>')
    else:
        p = ""
    return g + p + "</g>"


def keycap(x, y, label, w=None, colour=ACCENT):
    w = w or (24 + 11 * len(label))
    return (rect(x, y, w, 30, 8, "rgba(95,230,240,0.10)", "rgba(95,230,240,0.45)")
            + text(label, x + w / 2, y + 20, 14.5, colour, ROUND, "600", "middle"))


def badge(x, y, label, colour=ACCENT):
    w = 12 + 7.2 * len(label)
    return (rect(x, y, w, 15, 4, "rgba(95,230,240,0.12)")
            + text(label, x + w / 2, y + 11, 9, colour, ROUND, "700", "middle",
                   extra=' letter-spacing="0.6"')), w


# ── the sidebar ─────────────────────────────────────────────────────────────

ROWS = [
    ("Poe", "A quiet place to think. Your notes…", "now", None, True),
    ("The lantern", "It was the bell, and not the…", "3h", None, False),
    ("Package.swift", "// swift-tools-version:5.9", "Tue", "SWIFT", False),
    ("Reading list", "— Pale Fire, again", "Mar 4", "MD", False),
    ("scratch", "ffmpeg -i in.mov -vf scale…", "Mar 2", None, False),
]
DROPPED = ("notes.md", "# Groceries and the thing about…", "now", "MD", False)

ROW_Y, ROW_H, ROW_GAP = WY + 128, 48, 4


def sidebar_rows(rows, selected):
    body = []
    for i, (title, snippet, when, chip, pinned) in enumerate(rows):
        y = ROW_Y + i * (ROW_H + ROW_GAP)
        on = i == selected
        if on:
            body.append(rect(WX + 10, y, SB - 20, ROW_H, 10,
                             "rgba(95,230,240,0.10)", "rgba(95,230,240,0.28)"))
            body.append(rect(WX + 10, y + 10, 2.5, ROW_H - 20, 1.5, ACCENT))
        tx = WX + 24
        if pinned:
            body.append(icon("pin", WX + 26, y + 17, ACCENT, 10))
            tx = WX + 36
        body.append(text(title, tx, y + 21, 13, INK if on else "#CFD5E6",
                         ROUND, "600" if on else "500"))
        if chip:
            b, bw = badge(tx + 7.6 * len(title) + 8, y + 9, chip)
            body.append(b)
        body.append(text(snippet, tx, y + 38, 11.5, INKFNT, ROUND))
        body.append(text(when, WX + SB - 18, y + 21, 10.5, INKFNT, ROUND, "500", "end"))
    return "".join(body)


def sidebar_static():
    b = [rect(WX, WY, SB, WH, 0, "rgba(255,255,255,0.012)"),
         rect(WX + SB - 1, WY, 1, WH, 0, "rgba(255,255,255,0.055)")]
    # traffic lights
    for i, c in enumerate(("#FF5F57", "#FEBC2E", "#28C840")):
        b.append(f'<circle cx="{WX + 22 + i * 20}" cy="{WY + 22}" r="6" fill="{c}" opacity="0.9"/>')
    # wordmark
    b.append(lantern(WX + 18, WY + 45, 26, glow=False))
    b.append(text("poe", WX + 45, WY + 68, 20, "url(#glow)", ROUND, "600",
                  extra=' letter-spacing="1.5"'))
    # search field
    b.append(rect(WX + 14, WY + 82, SB - 28, 28, 9, "rgba(255,255,255,0.05)",
                  "rgba(255,255,255,0.075)"))
    b.append(icon("search", WX + 28, WY + 96, INKFNT, 11))
    b.append(text("Search", WX + 42, WY + 100, 12.5, INKFNT, ROUND))
    # new note
    b.append(rect(WX + 14, WY + WH - 52, SB - 28, 36, 10, "rgba(95,230,240,0.08)",
                  "rgba(95,230,240,0.30)"))
    b.append(icon("plus", WX + 104, WY + WH - 34, ACCENT, 12))
    b.append(text("New note", WX + 116, WY + WH - 29, 12.5, ACCENT, ROUND, "600"))
    b.append(text("⌘N", WX + SB - 26, WY + WH - 29, 11, INKFNT, ROUND, "500", "end"))
    return "".join(b)


def count_chip(n):
    return (f'<rect x="{WX + SB - 44}" y="{WY + 52}" width="26" height="18" rx="9" '
            f'fill="rgba(255,255,255,0.06)"/>'
            + text(str(n), WX + SB - 31, WY + 65, 11, INKFNT, ROUND, "600", "middle"))


# ── the editor pane ─────────────────────────────────────────────────────────

def toolbar(title, subtitle, previewing=False, x0=EX, w=EW, sidebar_on=True):
    b = [icon("sidebar", x0 + 24, WY + 34, INKDIM if sidebar_on else ACCENT),
         text(title, x0 + 46, WY + 30, 14, INK, ROUND, "600"),
         text(subtitle, x0 + 46, WY + 46, 10.5, INKFNT, ROUND)]
    right = x0 + w - 28
    for name in ("dots", "pencil" if previewing else "eye", "search", "pin"):
        b.append(icon(name, right, WY + 34,
                      ACCENT if (previewing and name == "pencil") else INKDIM))
        right -= 34
    return "".join(b)


def status(words, chars, note="Saved automatically", colour=ACCENT,
           x0=EX, w=EW, words_svg=None, chars_svg=None, minread=True):
    """The bar along the bottom: counts on the left, save state on the right.
    Fixed slots, so a counter climbing from 0 to 41 doesn't shove the labels."""
    y = WY + WH - 13
    b = [rect(x0, WY + WH - 34, w, 1, 0, "rgba(255,255,255,0.055)")]
    b.append(words_svg or text(str(words), x0 + 20, y, 10.5, INKDIM, ROUND, "600"))
    b.append(text("words", x0 + 48, y, 10.5, INKFNT, ROUND))
    b.append(f'<circle cx="{x0 + 92}" cy="{WY + WH - 17}" r="1.5" fill="{INKFNT}" opacity="0.5"/>')
    b.append(chars_svg or text(str(chars), x0 + 102, y, 10.5, INKDIM, ROUND, "600"))
    b.append(text("chars", x0 + 138, y, 10.5, INKFNT, ROUND))
    if minread:
        b.append(min_read(x0))
    b.append(f'<circle cx="{x0 + w - 26 - 5.9 * len(note):.1f}" cy="{WY + WH - 17}" '
             f'r="2.6" fill="{colour}" filter="url(#dotGlow)"/>')
    b.append(text(note, x0 + w - 20, y, 10.5, INKFNT, ROUND, "400", "end"))
    return "".join(b)


def min_read(x0):
    """The app only offers a reading time once a note is past 40 words."""
    y = WY + WH - 13
    return (f'<circle cx="{x0 + 176}" cy="{WY + WH - 17}" r="1.5" fill="{INKFNT}" opacity="0.5"/>'
            + text("1", x0 + 186, y, 10.5, INKDIM, ROUND, "600")
            + text("min read", x0 + 194, y, 10.5, INKFNT, ROUND))


def counter(x, y, values, t0, t1, fill=INKDIM):
    """A number that climbs. SMIL can't animate text content, so this is one
    <text> per value, each showing for its own slice of the typing."""
    n = len(values)
    b = []
    for i, v in enumerate(values):
        a = t0 + (t1 - t0) * i / n
        z = t0 + (t1 - t0) * (i + 1) / n
        frames = [(0.0, 0), (a, 0), (a, 1), (z, 1), (z, 1 if i == n - 1 else 0)]
        b.append(f'<text x="{x:.1f}" y="{y:.1f}" font-family="{ROUND}" font-size="10.5" '
                 f'font-weight="600" fill="{fill}" opacity="0">'
                 + anim("opacity", frames, "discrete") + f'{v}</text>')
    return "".join(b)


# ── scene timing ────────────────────────────────────────────────────────────

CARD   = [(0.0, 2.5), (25.9, TOTAL)]     # the title card opens and closes the loop
WINDOW = (2.2, 26.1)
S_TYPE  = (2.9, 10.4)
S_PREV  = (10.4, 15.0)
S_FIND  = (15.0, 19.0)
S_OPEN  = (19.0, 22.6)
S_FOCUS = (22.6, 26.0)

CAPTIONS = [
    (S_TYPE,  None, "Markdown takes hold as you write — the buffer stays exactly the text on disk."),
    (S_PREV,  "⌘P", "Render it. Same document, laid out."),
    (S_FIND,  "⌘F", "Find in this note — ⌘G steps through, ⌘E searches the selection."),
    (S_OPEN,  "⌘O", "Open any text file. Every keystroke goes back to disk, in its own encoding."),
    (S_FOCUS, "⌘0", "Focus mode. Everything else gets out of the way."),
]


# ── background ──────────────────────────────────────────────────────────────

out.append(rect(0, 0, W, H, 0, VOID))
orbs = [(180, 90, 190, ACCENT, 0.30, "0 0;40 -18;0 0", "26s"),
        (760, 780, 220, DEEP, 0.26, "0 0;-52 22;0 0", "31s"),
        (1120, 140, 200, VIOLET, 0.24, "0 0;28 34;0 0", "24s"),
        (1010, 700, 170, ROSE, 0.16, "0 0;-30 -26;0 0", "29s")]
aurora = "".join(
    f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{c}" opacity="{o}">'
    f'<animateTransform attributeName="transform" type="translate" values="{v}" '
    f'dur="{d}" repeatCount="indefinite"/></circle>'
    for cx, cy, r, c, o, v, d in orbs)
out.append(f'<g filter="url(#soft)" opacity="0.62">{aurora}</g>')


# ── the title card, which both opens and closes the loop ────────────────────

card = [
    lantern(566, 168, 166),
    text("poe", 640, 482, 104, INK, ROUND, "600", "middle",
         extra=' letter-spacing="-3"'),
    rect(490, 512, 300, 2, 1, "url(#rule)"),
    text("A quiet place to think.", 640, 562, 26, INKDIM, ROUND, "400", "middle"),
    text("MACOS · SWIFTUI · NO DEPENDENCIES · NO NETWORK", 640, 604, 13, ACCENT,
         ROUND, "500", "middle", 0.8, ' letter-spacing="2.4"'),
]
scene(CARD, "".join(card), fade=0.45)


# ── the window ──────────────────────────────────────────────────────────────

window = []
window.append(f'<ellipse cx="{WX + 130}" cy="{WY + 120}" rx="200" ry="180" fill="{LANT}" '
              f'opacity="0.10" filter="url(#soft)"/>')
window.append(rect(WX, WY, WW, WH, 16, "rgba(255,255,255,0.045)",
                   "rgba(255,255,255,0.075)", 1, ' filter="url(#drop)"'))
out.append(f'<g opacity="0">{gate(WINDOW, 0.4)}<g clip-path="url(#windowClip)">'
           + "".join(window) + "</g></g>")

# Everything from here on lives inside the window's rounded corners.
inner = []

# the sidebar, present for every scene but focus mode
inner.append(f'<g opacity="0">{gate((WINDOW[0], S_FOCUS[0] + 0.25), 0.35)}'
             + sidebar_static() + '</g>')
inner.append(f'<g opacity="0">{gate((WINDOW[0], S_OPEN[0] + 1.6), 0.3)}'
             + count_chip(5) + sidebar_rows(ROWS, 0) + '</g>')
inner.append(f'<g opacity="0">{gate((S_OPEN[0] + 1.45, S_FOCUS[0] + 0.25), 0.3)}'
             + count_chip(6) + sidebar_rows([DROPPED] + ROWS, 0) + '</g>')


# ── scene 1: typing ─────────────────────────────────────────────────────────

laid = doc_lines()
words = ["0", "3", "7", "11", "14", "18", "22", "27", "31", "35", "38", "41"]
chars = ["0", "22", "48", "74", "96", "121", "148", "170", "192", "214", "231", "244"]
placeholder = (f'<g opacity="0">{gate((S_TYPE[0], TS + 0.1), 0.2)}'
               + Span("Start writing…", INKFNT, 15, 9, MONO, opacity=0.6).svg(TX, TY)
               + '</g>')
inner.append(f'<g opacity="0">{gate(S_TYPE, 0.3)}'
             + toolbar("Poe", "Edited just now")
             + placeholder
             + typing(laid)
             + status(41, 244, minread=False,
                      words_svg=counter(EX + 20, WY + WH - 13, words, TS, TE),
                      chars_svg=counter(EX + 102, WY + WH - 13, chars, TS, TE))
             + f'<g opacity="0">{gate((TE - 1.1, S_TYPE[1]), 0.25)}{min_read(EX)}</g>'
             + '</g>')


# ── scene 2: the preview (⌘P) ───────────────────────────────────────────────

def prose(txt, x, y, size=15.5, fill="#C6CDE0", weight="400", style="normal"):
    return Span(txt, fill, size, size * 0.505, ROUND, weight, style).svg(x, y)


PX, PY = EX + 40, WY + 110
prev = [toolbar("Poe", "Edited just now", previewing=True),
        text("Poe", PX, PY, 31, INK, ROUND, "600", extra=' letter-spacing="-0.5"'),
        rect(PX, PY + 14, 120, 2, 1, "url(#rule)"),
        prose("A quiet place to think. Your notes never leave this", PX, PY + 54),
        prose("machine — every note lives in ", PX, PY + 80)]
prev.append(prose("one JSON file", PX + 30 * 7.83, PY + 80, 15.5, INK, "700"))
prev.append(prose(" you can read.", PX + 30 * 7.83 + 13 * 7.83, PY + 80))
for i, (done, line) in enumerate(((True, "a note styles itself as you type"),
                                  (False, "saving — it does that on its own"))):
    y = PY + 122 + i * 30
    prev.append(rect(PX + 1, y - 12, 15, 15, 4.5, "rgba(167,139,250,0.18)" if done else "none",
                     VIOLET if done else "rgba(255,255,255,0.22)", 1.4))
    if done:
        prev.append(f'<path d="M{PX + 4.5},{y - 4.5} L{PX + 7.5},{y - 1.5} L{PX + 13},{y - 8}" '
                    f'fill="none" stroke="{VIOLET}" stroke-width="1.8" stroke-linecap="round" '
                    f'stroke-linejoin="round"/>')
    prev.append(prose(line, PX + 26, y, 15.5, INKDIM if done else "#C6CDE0"))
prev.append(rect(PX, PY + 190, 3, 34, 1.5, VIOLET, extra=' opacity="0.65"'))
prev.append(prose("“Deep into that darkness peering…”", PX + 18, PY + 212, 15.5,
                  INKDIM, "400", "italic"))
prev.append(status(41, 244))
inner.append(f'<g opacity="0">{gate(S_PREV, 0.3)}' + "".join(prev) + '</g>')


# ── scene 3: find in this note (⌘F) ─────────────────────────────────────────

FIND_DY = 44
flaid = doc_lines(DOC, TX, TY + FIND_DY)


def matches(laid_, word):
    """Where `word` sits on screen, from the same stops the typing walks."""
    hits = []
    for ln in laid_:
        plain = "".join(s.text for _, s in ln["body"])
        start = 0
        while True:
            i = plain.lower().find(word, start)
            if i < 0:
                break
            hits.append((ln["stops"][i], ln["y"], ln["stops"][i + len(word)] - ln["stops"][i]))
            start = i + 1
    return hits


hits = matches(flaid, "note")
find = [toolbar("Poe", "Edited just now")]
find.append(rect(EX, WY + 62, EW, FIND_DY, 0, "rgba(255,255,255,0.03)"))
find.append(rect(EX, WY + 62 + FIND_DY - 1, EW, 1, 0, "rgba(255,255,255,0.055)"))
find.append(icon("search", EX + 30, WY + 84, ACCENT, 13))
find.append(rect(EX + 44, WY + 72, 230, 24, 7, "rgba(255,255,255,0.05)",
                 "rgba(95,230,240,0.45)"))
find.append(text("note", EX + 54, WY + 89, 12.5, INK, MONO))
find.append(f'<rect x="{EX + 54 + 4 * 7.5 + 1}" y="{WY + 77}" width="1.6" height="14" '
            f'fill="{ACCENT}"><animate attributeName="opacity" values="1;1;0.1;1" '
            f'dur="1.05s" repeatCount="indefinite"/></rect>')
find.append(text("2 of 3", EX + 288, WY + 89, 11.5, INKFNT, ROUND, "500"))
find.append(icon("chevup", EX + 348, WY + 84, INKDIM, 14))
find.append(icon("chevdown", EX + 374, WY + 84, INKDIM, 14))
find.append(text("Done", EX + EW - 24, WY + 89, 11.5, INKDIM, ROUND, "500", "end"))
for i, (x, y, w) in enumerate(hits):
    on = i == 1
    find.append(rect(x - 2, y - 15, w + 4, 21, 4,
                     "rgba(95,230,240,0.30)" if on else "rgba(95,230,240,0.13)",
                     ACCENT if on else None, 1))
find.append(render_doc(flaid))
find.append(status(41, 244))
inner.append(f'<g opacity="0">{gate(S_FIND, 0.3)}' + "".join(find) + '</g>')


# ── scene 4: opening a file (⌘O, or drop it on the window) ──────────────────

DOC2 = [
    [mono("# ", INKFNT, opacity=0.8), Span("Groceries", ACCENT, 22, 12.4, ROUND, "600")],
    [],
    [mono("- ", INKFNT, opacity=0.8), mono("[x] ", VIOLET, "700"),
     mono("coffee, the good bag", INKDIM)],
    [mono("- ", INKFNT, opacity=0.8), mono("[ ] ", INKFNT), mono("limes")],
    [mono("- ", INKFNT, opacity=0.8), mono("[ ] ", INKFNT),
     mono("a notebook, paper, for once")],
    [],
    [mono("Tuesday: ring the shop about the ")],
    [mono("lamp", INK), mono(" — the one with the ", INK),
     mono("**", INKFNT, opacity=0.75), mono("brass", INK, "700"),
     mono("**", INKFNT, opacity=0.75), mono(" shade.")],
]

card_w, card_h = 172, 46
fly_frames = [(0.0, "1140 860"), (S_OPEN[0], "1140 860"), (S_OPEN[0] + 1.05, "554 292"),
              (S_OPEN[0] + 1.35, "554 300"), (TOTAL, "554 300")]
fly = (f'<g>' + rect(0, 0, card_w, card_h, 12, "rgba(10,12,20,0.92)", "rgba(95,230,240,0.45)")
       + icon("doc", 24, card_h / 2, ACCENT, 16)
       + text("notes.md", 44, card_h / 2 + 5, 13.5, INK, ROUND, "600")
       + f'<animateTransform attributeName="transform" type="translate" '
         f'values="{";".join(v for _, v in fly_frames)}" '
         f'keyTimes="{";".join(f"{t / TOTAL:.6f}" for t, _ in fly_frames)}" '
         f'dur="{TOTAL}s" repeatCount="indefinite"/></g>')

drop = (rect(WX + 14, WY + 14, WW - 28, WH - 28, 18, "rgba(8,9,14,0.55)",
             "rgba(95,230,240,0.65)", 2, ' stroke-dasharray="7 6"')
        + text("Drop to open", WX + WW / 2, WY + WH / 2 + 12, 15, INK, ROUND, "600", "middle")
        + text("Markdown, plain text, code — anything text",
               WX + WW / 2, WY + WH / 2 + 36, 11.5, INKFNT, ROUND, "400", "middle"))

opened = [toolbar("notes.md", "~/Documents/notes.md"),
          render_doc(doc_lines(DOC2)),
          status(23, 141, "Saving to notes.md")]
b, bw = badge(EX + 46 + 8 * 7.6 + 8, WY + 21, "MD")
opened.append(b)

inner.append(f'<g opacity="0">{gate(S_OPEN, 0.28)}'
             f'<g opacity="0">{gate((S_OPEN[0], S_OPEN[0] + 1.6), 0.22)}{fly}{drop}</g>'
             f'<g opacity="0">{gate((S_OPEN[0] + 1.5, S_OPEN[1]), 0.25)}'
             + "".join(opened) + '</g></g>')


# ── scene 5: focus mode (⌘0) ────────────────────────────────────────────────

FDY = 22
focus = [f'<g>' + "".join(
    f'<circle cx="{WX + 22 + i * 20}" cy="{WY + 22}" r="6" fill="{c}" opacity="0.9"/>'
    for i, c in enumerate(("#FF5F57", "#FEBC2E", "#28C840"))) + '</g>']
ftool = toolbar("notes.md", "~/Documents/notes.md", x0=WX, w=WW, sidebar_on=False)
focus.append(f'<g transform="translate(0,{FDY})">{ftool}</g>')
b2, _ = badge(WX + 46 + 8 * 7.6 + 8, WY + 21 + FDY, "MD")
focus.append(b2)
focus.append(render_doc(doc_lines(DOC2, WX + 34, TY + FDY + 8)))
focus.append(status(23, 141, "Saving to notes.md", x0=WX, w=WW))
inner.append(f'<g opacity="0">{gate(S_FOCUS, 0.3)}' + "".join(focus) + '</g>')

out.append(f'<g opacity="0">{gate(WINDOW, 0.4)}<g clip-path="url(#windowClip)">'
           + "".join(inner) + '</g></g>')


# ── captions and the scrubber ───────────────────────────────────────────────

for (a, b_), key, line in CAPTIONS:
    x = WX + 4
    body = []
    if key:
        body.append(keycap(x, 722, key))
        x += 24 + 11 * len(key) + 16
    body.append(text(line, x, 743, 15, INKDIM, ROUND, "400"))
    scene((a + 0.15, b_), "".join(body), fade=0.25)

out.append(rect(WX, 782, WW, 3, 1.5, "rgba(255,255,255,0.07)"))
out.append(rect(WX, 782, 1, 3, 1.5, "url(#rule)")
           .replace('width="1.0"', 'width="0"')
           .replace("/>", ">" + anim("width", [(0, 0), (TOTAL, WW)]) + "</rect>"))
for a, _ in (S_TYPE, S_PREV, S_FIND, S_OPEN, S_FOCUS):
    out.append(rect(WX + WW * a / TOTAL, 778, 1, 11, 0, "rgba(255,255,255,0.16)"))
out.append(text("poe — a quiet place to think", WX, 770, 10.5, INKFNT, ROUND, "500",
                extra=' letter-spacing="1.6"', opacity=0.7))
out.append(text("28s · loops", WX + WW, 770, 10.5, INKFNT, ROUND, "500", "end", 0.7))


# ── assemble ────────────────────────────────────────────────────────────────

DEFS = f'''
  <radialGradient id="glassGlow" gradientUnits="userSpaceOnUse" cx="50" cy="82" r="26">
    <stop offset="0" stop-color="{FLAME}"/><stop offset="0.5" stop-color="{LANT}"/>
    <stop offset="1" stop-color="#FA9205" stop-opacity="0.85"/>
  </radialGradient>
  <linearGradient id="flameGrad" gradientUnits="userSpaceOnUse" x1="50" y1="72" x2="50" y2="89">
    <stop offset="0" stop-color="#FA9205"/><stop offset="0.5" stop-color="{LANT}"/>
    <stop offset="1" stop-color="#FFFFFF"/>
  </linearGradient>
  <linearGradient id="skirtGrad" gradientUnits="userSpaceOnUse" x1="31" y1="47" x2="69" y2="56">
    <stop offset="0" stop-color="{FRAME}"/><stop offset="1" stop-color="{FRAMED}"/>
  </linearGradient>
  <linearGradient id="fountGrad" gradientUnits="userSpaceOnUse" x1="34" y1="100" x2="66" y2="114">
    <stop offset="0" stop-color="{FRAME}"/><stop offset="1" stop-color="{FRAMED}"/>
  </linearGradient>
  <linearGradient id="glow" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="{ACCENT}"/><stop offset="0.5" stop-color="{DEEP}"/>
    <stop offset="1" stop-color="{VIOLET}"/>
  </linearGradient>
  <linearGradient id="rule" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="{ACCENT}"/><stop offset="0.5" stop-color="{DEEP}"/>
    <stop offset="1" stop-color="{VIOLET}"/>
  </linearGradient>
  <clipPath id="glassClip">
    <path d="M37,55 C30,68 30,82 37,95 L63,95 C70,82 70,68 63,55 Z"/>
  </clipPath>
  <clipPath id="windowClip"><rect x="{WX}" y="{WY}" width="{WW}" height="{WH}" rx="16"/></clipPath>
  <filter id="soft" x="-60%" y="-60%" width="220%" height="220%">
    <feGaussianBlur stdDeviation="70"/>
  </filter>
  <filter id="halo" x="-90%" y="-90%" width="280%" height="280%">
    <feGaussianBlur stdDeviation="16"/>
  </filter>
  <filter id="caretGlow" x="-400%" y="-100%" width="900%" height="300%">
    <feGaussianBlur stdDeviation="1.6" result="b"/>
    <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  <filter id="dotGlow" x="-300%" y="-300%" width="700%" height="700%">
    <feGaussianBlur stdDeviation="2.2" result="b"/>
    <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  <filter id="drop" x="-20%" y="-20%" width="140%" height="140%">
    <feDropShadow dx="0" dy="18" stdDeviation="26" flood-color="#000000" flood-opacity="0.55"/>
  </filter>
{"".join("  " + d for d in defs)}'''

svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" '
       f'height="{H}" role="img" aria-label="A demo of Poe: typing markdown that '
       f'styles itself, the ⌘P preview, find in note, opening a file, and focus mode">\n'
       f'<title>Poe — a quiet place to think</title>\n<defs>{DEFS}</defs>\n'
       + "\n".join(out) + "\n</svg>\n")

path = Path(__file__).resolve().parent.parent / "assets" / "demo.svg"
path.write_text(svg, encoding="utf-8")
print(f"{path} — {len(svg) / 1024:.0f} KB, {TOTAL:.0f}s loop")
