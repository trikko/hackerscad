#!/usr/bin/env python3
# The GUI's symbolic icons (data/icons/hicolor/scalable/actions/hcad-*-symbolic.svg),
# drawn here as 1-pixel strokes on a 16-pixel grid and written as filled outlines:
# GTK recolours a symbolic icon by its fills, so the strokes are turned into paths
# by Inkscape. Edit a drawing here, never the SVG it makes.
# Needs Inkscape 1.x. Usage: python3 tools/icons.py [name...]
import os, re, subprocess, sys, tempfile, math
import xml.etree.ElementTree as ET

base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(base, 'data/icons/hicolor/scalable/actions')

# drawing markup: s = a stroke, w = a thicker stroke, d = a dashed stroke,
# t = a tinted fill, T = a darker tinted fill, f = a solid fill; faint = drawn at 40%
FRAME = '<rect class="s" x="1.5" y="2.5" width="13" height="11" rx="2"/>'
CUBE = '<path class="s" d="M8 1.5 13.5 4.5v7L8 14.5 2.5 11.5v-7ZM2.5 4.5 8 7.5l5.5-3M8 7.5v7"/>'
FAINT_CUBE = '<g class="faint">' + CUBE + '</g>'


def hatch(cx, cy, r, step):
    # 45° lines across the right half of a circle, between its centre line and its edge
    d = []
    c = cx + cy - r
    while c < cx + cy + r * math.sqrt(2):
        c += step
        # on y = c - x: from x = cx to where the line leaves the circle
        y0 = c - cx
        if not (cy - r < y0 < cy + r):
            continue
        # (x-cx)² + (c-x-cy)² = r²
        k = c - cy
        a, b, cc = 2, -2 * (cx + k), cx * cx + k * k - r * r
        disc = b * b - 4 * a * cc
        if disc <= 0:
            continue
        x1 = (-b + math.sqrt(disc)) / (2 * a)
        if x1 - cx < 0.8:
            continue
        d.append(f'M{cx:.2f} {y0:.2f}L{x1:.2f} {c - x1:.2f}')
    return ''.join(d)


ICONS = {
    # header bar
    'new': ('a page with a plus',
            '<path class="s" d="M9.5 1.5H5A1.5 1.5 0 0 0 3.5 3v10A1.5 1.5 0 0 0 5 14.5h3.5M9.5 1.5 13 5v3.5M9.5 1.5V5H13M12.5 10v5M10 12.5h5"/>'),
    'open': ('an open folder',
             '<path class="s" d="M1.5 13.5V3.5a1 1 0 0 1 1-1H6l1.5 1.5h4.5a1 1 0 0 1 1 1v2.5M1.5 13.5l2-6h11l-2 6Z"/>'),
    'save': ('a floppy disk',
             '<path class="s" d="M2.5 3.5a1 1 0 0 1 1-1h8l2 2v8a1 1 0 0 1-1 1h-9a1 1 0 0 1-1-1ZM5.5 2.5v3h4v-3M5 13.5v-4h6v4"/>'),
    'rebuild': ('rebuilding as one types: circling arrows round a lightning bolt',
                '<path class="s" d="M13.5 8a5.5 5.5 0 1 1-1.6-3.9M12.5 1.5v3h-3"/><path class="f" d="M8.7 4.8 6.2 8.6H8l-.7 2.6L9.8 7.4H8Z"/>'),
    'agent': ('a robot head',
              '<rect class="s" x="3.5" y="5.5" width="9" height="8" rx="2"/><path class="s" d="M8 5.5v-2M1.5 8.5v2M14.5 8.5v2M6.5 11.5h3"/>'
              '<circle class="f" cx="8" cy="2.5" r="1"/><circle class="f" cx="6.25" cy="8.75" r=".9"/><circle class="f" cx="9.75" cy="8.75" r=".9"/>'),
    'menu': ('three lines', '<path class="s" d="M2.5 3.5h11M2.5 7.5h11M2.5 11.5h11"/>'),
    # the panels, one family: a window with its part shaded
    'panel-code': ('the code panel: a window, its left part shaded',
                   FRAME + '<path class="t" d="M6.5 2.5v11h-3a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2Z"/><path class="s" d="M6.5 2.5v11"/>'),
    'panel-view': ('the 3D view: a window, its middle shaded',
                   FRAME + '<path class="t" d="M5.5 2.5h5v11h-5Z"/><path class="s" d="M5.5 2.5v11M10.5 2.5v11"/>'),
    'panel-params': ('the parameters panel: a window, its right part shaded',
                     FRAME + '<path class="t" d="M9.5 2.5v11h3a2 2 0 0 0 2-2v-7a2 2 0 0 0-2-2Z"/><path class="s" d="M9.5 2.5v11"/>'),
    'panel-console': ('the console: a window, its bottom shaded',
                      FRAME + '<path class="t" d="M1.5 9.5h13v2a2 2 0 0 1-2 2h-9a2 2 0 0 1-2-2Z"/><path class="s" d="M1.5 9.5h13"/>'),
    # the 3D view's toolbar
    'select-part': ('select whole parts: a cube', CUBE),
    'select-face': ('select faces: a faint cube, its top face shaded',
                    FAINT_CUBE + '<path class="t" d="M8 1.5 13.5 4.5 8 7.5 2.5 4.5Z"/><path class="s" d="M8 1.5 13.5 4.5 8 7.5 2.5 4.5Z"/>'),
    'select-edge': ('select edges: a faint cube, its front edge thick', FAINT_CUBE + '<path class="w" d="M8 7.5v7"/>'),
    'select-vertex': ('select vertices: a faint cube, a dot on its front corner',
                      FAINT_CUBE + '<circle class="f" cx="8" cy="7.5" r="1.75"/>'),
    'eye': ('parts shown: an eye with lashes',
            '<path class="s" d="M1.5 9Q8 2 14.5 9M1.5 9Q8 14.5 14.5 9M8 5.5v-2M4.4 6.6 3.3 4.9M11.6 6.6l1.1-1.7"/><circle class="f" cx="8" cy="9" r="2.1"/>'),
    'display': ('display style: a shaded box, its hidden edges dashed',
                '<path class="t" d="M2.5 5.5 5.5 2.5h8v8l-3 3h-8Z"/><path class="s" d="M2.5 5.5h8v8h-8ZM2.5 5.5l3-3h8l-3 3M13.5 2.5v8l-3 3"/>'
                '<path class="d" d="M5.5 2.5v8h8M5.5 10.5l-3 3"/>'),
    'planes': ('planes: XY, XZ and YZ at the origin, the axes coming out of them',
               '<path class="t" d="M8 9 12.5 11.25 8 13.5 3.5 11.25Z"/><path class="T" d="M8 9 12.5 11.25v-6L8 3Z"/><path class="t" d="M8 9 3.5 11.25v-6L8 3Z"/>'
               '<path class="s" d="M8 9V1.5M8 9l6.5 3.25M8 9l-6.5 3.25M12.5 11.25v-6L8 3 3.5 5.25v6L8 13.5l4.5-2.25"/>'),
    'section': ('section: a round body cut by a plane, the cut half hatched',
                '<circle class="s" cx="8" cy="8" r="5.5"/><path class="s" d="M8 1v14"/><path class="s" d="' + hatch(8, 8, 5.5, 2.6) + '"/>'),
    'flip': ('flip the section: arrows up and down', '<path class="s" d="M8 2v12M5.5 4.5 8 2l2.5 2.5M5.5 11.5 8 14l2.5-2.5"/>'),
    'inspect': ('inspect: a viewfinder round a small solid',
                '<path class="s" d="M1.5 5V3A1.5 1.5 0 0 1 3 1.5h2M11 1.5h2A1.5 1.5 0 0 1 14.5 3v2M14.5 11v2a1.5 1.5 0 0 1-1.5 1.5h-2M5 14.5H3A1.5 1.5 0 0 1 1.5 13v-2"/>'
                '<path class="s" d="M8 4.5 11 6v4L8 11.5 5 10V6ZM5 6l3 1.5L11 6M8 7.5v4"/>'),
    'annotate': ('annotate: a pencil and the line it draws',
                 '<path class="s" d="M10.5 2.5 13.5 5.5 6 13H3v-3ZM9 4l3 3M9.5 13.5h4"/>'),
    'pan': ('pan: four arrows', '<path class="s" d="M8 1.5v13M1.5 8h13M6 3.5l2-2 2 2M6 12.5l2 2 2-2M3.5 6l-2 2 2 2M12.5 6l2 2-2 2"/>'),
    # annotation tools
    'mark-arrow': ('an arrow', '<path class="s" d="M3 13 13 3M7 3h6v6"/>'),
    'mark-cross': ('a cross with a gap at the point it marks',
                   '<path class="s" d="M8 1.5v4M8 10.5v4M1.5 8h4M10.5 8h4"/><circle class="f" cx="8" cy="8" r=".9"/>'),
    'mark-circle': ('an ellipse', '<ellipse class="s" cx="8" cy="8" rx="6.5" ry="5"/>'),
    'mark-freehand': ('a line drawn by hand', '<path class="s" d="M1.5 11.5C3 5 5.5 4.5 7 8s3.5 4 5-.5c.7-2.2 1.5-3.5 2.5-3.5"/>'),
    'mark-text': ('a text', '<path class="s" d="M3 4.5v-2h10v2M8 2.5v11M6 13.5h4"/>'),
    # side panel and console
    'params': ('parameters: three sliders',
               '<path class="s" d="M1.5 3.5h3M7.5 3.5h7M1.5 8h8M12.5 8h2M1.5 12.5h2M6.5 12.5h8"/>'
               '<circle class="s" cx="6" cy="3.5" r="1.5"/><circle class="s" cx="11" cy="8" r="1.5"/><circle class="s" cx="5" cy="12.5" r="1.5"/>'),
    'steps': ('steps: a timeline',
              '<circle class="s" cx="4" cy="3.5" r="1.5"/><circle class="s" cx="4" cy="8" r="1.5"/><circle class="s" cx="4" cy="12.5" r="1.5"/>'
              '<path class="s" d="M4 5v1.5M4 9.5V11M7.5 3.5h7M7.5 8h7M7.5 12.5h4"/>'),
    'test': ('unittests: a flask',
             '<path class="s" d="M6 1.5h4M6.75 1.5V6l-3.9 6.4a1 1 0 0 0 .85 1.6h8.6a1 1 0 0 0 .85-1.6L9.25 6V1.5M4.6 10.5h6.8"/>'),
    # small actions
    'copy': ('two sheets', '<rect class="s" x="5.5" y="5.5" width="9" height="9" rx="1.5"/><path class="s" d="M10.5 5.5v-2a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2"/>'),
    'replace': ('two arrows the opposite way', '<path class="s" d="M2.5 5.5h10l-2.5-2.5M13.5 10.5h-10l2.5 2.5"/>'),
    'undo': ('an arrow turning back', '<path class="s" d="M5.5 3.5 2.5 6.5l3 3M2.5 6.5H10a3.5 3.5 0 0 1 0 7H7"/>'),
    'up': ('a chevron up', '<path class="s" d="M3.5 10 8 5.5l4.5 4.5"/>'),
    'down': ('a chevron down', '<path class="s" d="M3.5 6 8 10.5 12.5 6"/>'),
    'next': ('a chevron right', '<path class="s" d="M6 3.5 10.5 8 6 12.5"/>'),
    'close': ('a cross', '<path class="s" d="M4 4l8 8M12 4l-8 8"/>'),
    'apply': ('a check mark', '<path class="s" d="M2.5 8.5l3.5 3.5 7.5-7.5"/>'),
    'pin': ('a pin', '<path class="s" d="M5.5 1.5h5M6.75 1.5 6.25 5.5C4.75 6.25 4 7.75 4 9.5h8c0-1.75-.75-3.25-2.25-4l-.5-4M8 9.5v5"/>'),
    'folder': ('a folder', '<path class="s" d="M1.5 4a1.5 1.5 0 0 1 1.5-1.5h3l1.5 1.5h5.5a1.5 1.5 0 0 1 1.5 1.5v6.5a1.5 1.5 0 0 1-1.5 1.5H3A1.5 1.5 0 0 1 1.5 12Z"/>'),
    'external-link': ('a box with an arrow leaving it',
                      '<path class="s" d="M12.5 9v3.5a1 1 0 0 1-1 1h-8a1 1 0 0 1-1-1v-8a1 1 0 0 1 1-1H7M10 2.5h3.5V6M13.5 2.5l-6 6"/>'),
    'error': ('an exclamation mark in a circle',
              '<circle class="s" cx="8" cy="8" r="6.5"/><path class="s" d="M8 4.5V9"/><circle class="f" cx="8" cy="11.25" r=".85"/>'),
    'warning': ('an exclamation mark in a triangle',
                '<path class="s" d="M8 1.75 14.75 13.5H1.25ZM8 6v3.5"/><circle class="f" cx="8" cy="11.4" r=".85"/>'),
}

STYLE = {
    's': 'fill:none;stroke:#000;stroke-width:1;stroke-linecap:round;stroke-linejoin:round',
    'w': 'fill:none;stroke:#000;stroke-width:2;stroke-linecap:round;stroke-linejoin:round',
    'd': 'fill:none;stroke:#000;stroke-width:1;stroke-linecap:butt;stroke-dasharray:1.5,1.25',
    't': 'fill:#000;fill-opacity:0.25;stroke:none',
    'T': 'fill:#000;fill-opacity:0.45;stroke:none',
    'f': 'fill:#000;stroke:none',
}


def source(markup):
    # the class names as Inkscape styles; a faint group's strokes at 40%
    def styled(m):
        return f'style="{STYLE[m.group(1)]}"'
    body = re.sub(r'class="(\w)"', styled, markup)
    body = body.replace('<g class="faint">', '<g style="opacity:0.4">')
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">{body}</svg>'


def opacity_of(el, parents):
    o = 1.0
    for e in parents + [el]:
        st = dict(kv.split(':', 1) for kv in e.get('style', '').split(';') if ':' in kv)
        o *= float(st.get('opacity', e.get('opacity', 1)))
        if e is el:
            o *= float(st.get('fill-opacity', e.get('fill-opacity', 1)))
    return round(o, 2)


def paths(svgfile):
    ns = '{http://www.w3.org/2000/svg}'
    found = []

    def walk(e, parents):
        if e.get('transform'):
            sys.exit(f'{svgfile}: a transform Inkscape left, not expected')
        if e.tag == ns + 'path':
            found.append((opacity_of(e, parents), e.get('d')))
        for c in e:
            if c.tag != ns + 'defs':
                walk(c, parents + [e] if e.tag == ns + 'g' else parents)
    walk(ET.parse(svgfile).getroot(), [])
    return found


def build(name, comment, markup, tmp):
    src = os.path.join(tmp, name + '.svg')
    dst = os.path.join(tmp, name + '-out.svg')
    open(src, 'w').write(source(markup))
    subprocess.run(['inkscape', src, '--actions=select-all:all;object-to-path;select-all:all;object-stroke-to-path;'
                    f'export-plain-svg;export-filename:{dst};export-do'], check=True, capture_output=True)
    lines = [f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">',
             f'  <!-- {comment} (made by tools/icons.py: 1-pixel strokes as filled outlines, for symbolic recolouring) -->']
    for o, d in paths(dst):
        d = re.sub(r'(\d+\.\d{3})\d+', r'\1', d)
        op = '' if o == 1 else f' fill-opacity="{o}"'
        lines.append(f'  <path fill="#2e3436"{op} d="{d}"/>')
    lines.append('</svg>')
    open(os.path.join(out, f'hcad-{name}-symbolic.svg'), 'w').write('\n'.join(lines) + '\n')


names = sys.argv[1:] or list(ICONS)
with tempfile.TemporaryDirectory() as tmp:
    for n in names:
        build(n, *ICONS[n], tmp)
        print('hcad-' + n + '-symbolic.svg')
