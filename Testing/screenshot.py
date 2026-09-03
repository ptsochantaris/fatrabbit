#!/usr/bin/env python3
"""Replays a terminal capture into a virtual screen and prints what would have been on it.

    python3 screenshot.py <capture-file> <columns> <rows> [frame]

Enough of a terminal to check a full-screen display: absolute cursor positioning, erase-line and
erase-screen, the alternate screen buffer, and SGR colour. Anything else is skipped rather than
guessed at.

Without `frame` it prints the last frame drawn. With a number it prints that frame, counting from
one, so a run can be inspected part way through — `1` is usually the first thing on screen and
useful for checking a phase that has since passed. Frames are counted by cursor-home, which is
how the display starts each one.

Three things come out, and between them they catch the mistakes that matter:

  the frame itself      as plain text, so the layout, the widths and the box can be read
  a colour census      how many cells of each palette colour, which says whether the grid is
                       showing what it should — a volume that is 9% full and drawing 90% green
                       is wrong in a way no amount of squinting at text will show
  what came after      bytes written once the alternate screen was left, which is the replayed
                       transcript, and has to be there or the run's record has been lost

Exit status is 1 if any row overruns the window width, since that is the fault that corrupts a
frame invisibly — the terminal wraps, every later row is one out, and nothing looks wrong until
the whole frame drifts.
"""

import re
import sys

SGR = re.compile(rb'\x1b\[([0-9;]*)m')

# The palette fatrabbit draws with, as one letter per category, so the grid can be read as text.
# Three shades of each mean three entries: sparse, half full, full.
#
# An unmapped colour draws as a space rather than as a complaint, so anything missing here is a
# category the grid renders as empty volume — which reads as a bug in the tool being measured rather
# than in the measuring. The census counts raw colour numbers and would still show it; this map is
# what makes it locatable. Keep it in step with `Palette`.
LETTERS = {238: '.',
           28: 'f', 34: 'F', 46: 'F',
           130: 'm', 172: 'M', 214: 'M',
           25: 'k', 32: 'K', 39: 'K',
           148: 'n', 184: 'N', 226: 'N',
           133: 'g', 170: 'G', 213: 'G',
           249: 's', 251: 'S', 254: 'S',
           196: 'X'}

# Activity is a background behind the contents, so a busy cell reports both.
ACTIVITY = {27: 'r', 142: 'w', 127: 'p', 88: 'c', 239: 'F', 245: 'F'}

MAP_GLYPH = '▪'


def is_map_cell(cell):
    """A map cell is the small square carrying a foreground colour. The key's swatch is a circle, so
    the two are never confused for one another."""
    return cell[0] == MAP_GLYPH and cell[1] is not None


def is_map_row(row):
    return any(is_map_cell(cell) for cell in row)


class Screen:
    def __init__(self, columns, rows):
        self.columns = columns
        self.rows = rows
        self.clear()
        self.foreground = None
        self.background = None
        self.overruns = []

    def clear(self):
        self.cells = [[(' ', None, None)] * self.columns for _ in range(self.rows)]
        self.row = 0
        self.column = 0

    def put(self, character):
        if self.column >= self.columns:
            self.overruns.append(self.row + 1)
            return                                  # autowrap is off, so the cell is simply lost
        self.cells[self.row][self.column] = (character, self.foreground, self.background)
        self.column += 1

    def text(self):
        return '\n'.join(''.join(cell[0] for cell in row).rstrip() for row in self.cells)

    def census(self):
        counts = {}
        for row in self.cells:
            for character, foreground, background in row:
                for colour in (foreground, background):
                    if colour is not None:
                        counts[colour] = counts.get(colour, 0) + 1
        return counts

    def letters(self):
        """The grid as one letter per map cell, so where the colours are can be read.

        A cell being read or written reports that instead of its contents — both are on screen at
        once, but one letter cannot say two things, and activity is the part worth watching.
        """
        out = []
        for row in self.cells:
            if not is_map_row(row):
                continue
            line = ''
            for cell in row:
                if not is_map_cell(cell):
                    continue
                line += ACTIVITY.get(cell[2]) or LETTERS.get(cell[1], ' ')
            out.append(line)
        return out


def replay(data, columns, rows, wanted, keep=None):
    """Replays the capture. `keep` is a set of frame numbers to snapshot whole, collected in this
    one pass — the capture from a real run is megabytes, and walking it once per wanted frame is
    the difference between a second and a minute."""
    screen = Screen(columns, rows)
    frames = 0
    snapshot = None
    kept = {}
    index = 0
    left_alternate_at = None

    while index < len(data):
        byte = data[index]
        if byte != 0x1B:
            if byte == 0x0A:
                screen.row = min(screen.row + 1, rows - 1)
                screen.column = 0
            elif byte == 0x0D:
                screen.column = 0
            elif byte >= 0x20 or byte >= 0x80:
                # Decode one character, which may be several bytes of UTF-8.
                end = index + 1
                while end < len(data) and 0x80 <= data[end] < 0xC0:
                    end += 1
                screen.put(data[index:end].decode('utf-8', 'replace'))
                index = end
                continue
            index += 1
            continue

        match = re.match(rb'\x1b\[([0-9;?]*)([A-Za-z])', data[index:])
        if not match:
            index += 1
            continue
        parameters, final = match.group(1), match.group(2)
        index += match.end()

        if final == b'H':
            numbers = [int(n) for n in parameters.split(b';') if n != b''] or [1, 1]
            screen.row = min(max(numbers[0] - 1, 0), rows - 1)
            screen.column = min(max((numbers[1] if len(numbers) > 1 else 1) - 1, 0), columns - 1)
            if screen.row == 0 and screen.column == 0:
                if frames > 0:
                    if wanted is None or frames == wanted:
                        snapshot = screen.text(), screen.census(), screen.letters()
                    if keep and frames in keep:
                        copy = Screen(columns, rows)
                        copy.cells = [list(row) for row in screen.cells]
                        kept[frames] = copy
                frames += 1
        elif final == b'J' and parameters in (b'2', b''):
            screen.clear()
        elif final == b'K':
            # From the cursor inclusive. With autowrap off the cursor cannot advance past the last
            # column, so a row that fills the window leaves it sitting on the final character — and
            # this erases that character. Modelling the clamp is what catches an erase issued after
            # a full-width row rather than before it, which silently deletes the right-hand border.
            for column in range(min(screen.column, columns - 1), columns):
                screen.cells[screen.row][column] = (' ', None, None)
        elif final == b'm':
            for number in [int(n) for n in parameters.split(b';') if n != b''] or [0]:
                if number == 0:
                    screen.foreground = screen.background = None
            # 38;5;n and 48;5;n, read as a whole rather than one number at a time.
            numbers = [int(n) for n in parameters.split(b';') if n != b'']
            for position in range(len(numbers) - 2):
                if numbers[position] == 38 and numbers[position + 1] == 5:
                    screen.foreground = numbers[position + 2]
                if numbers[position] == 48 and numbers[position + 1] == 5:
                    screen.background = numbers[position + 2]
        elif final == b'l' and parameters == b'?1049':
            # Everything past here is the replayed transcript, which is ordinary scrolling output
            # and none of this emulator's business — counting it as frame content would report
            # overruns for lines the real terminal simply wraps.
            left_alternate_at = index
            break

    # Frames are snapshotted when the *next* one starts, so the final frame — which is the one
    # holding the finished run — has no boundary after it and would otherwise never be seen.
    if snapshot is None or wanted is None:
        snapshot = screen.text(), screen.census(), screen.letters()
    if keep and frames in keep:
        copy = Screen(columns, rows)
        copy.cells = [list(row) for row in screen.cells]
        kept[frames] = copy
    return frames, snapshot, left_alternate_at, screen.overruns, kept


def xterm_palette():
    """The 256-colour palette as hex, so a capture can be looked at rather than described."""
    basic = [(0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238), (205, 0, 205),
             (0, 205, 205), (229, 229, 229), (127, 127, 127), (255, 0, 0), (0, 255, 0),
             (255, 255, 0), (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]
    colours = list(basic)
    steps = [0, 95, 135, 175, 215, 255]
    for r in steps:
        for g in steps:
            for b in steps:
                colours.append((r, g, b))
    for grey in range(24):
        level = 8 + grey * 10
        colours.append((level, level, level))
    return ['#%02x%02x%02x' % colour for colour in colours]


# Character cell in the rendered output. The map is drawn as rectangles of exactly this size, so
# the picture never depends on what the browser does with a font.
CELL_W, CELL_H = 6, 12


def svg(rows, columns, palette):
    """Draws map rows as rectangles: the whole cell where it is being read or written, and a small
    square inside it for what the cell holds — which is what the terminal shows, a coloured
    background behind a coloured glyph.

    Rectangles rather than text because the first version of this drew the frame as coloured spans,
    and at a font size whose advance was not a whole number of pixels the browser left hairline gaps
    of the page behind showing between them. That read as dashes scattered through the map — an
    artefact of the preview being reported as corruption in the tool, which is the one thing a
    preview must never do.
    """
    inset_x, inset_y, size = 1, 4, CELL_W - 2
    parts = [f'<svg width="{columns * CELL_W}" height="{len(rows) * CELL_H}" '
             f'shape-rendering="crispEdges">']
    for y, row in enumerate(rows):
        # Activity first, as a full cell, so the contents sit on top of it.
        x = 0
        while x < len(row):
            if not is_map_cell(row[x]) or row[x][2] is None:
                x += 1
                continue
            colour = row[x][2]
            run = 1
            while x + run < len(row) and is_map_cell(row[x + run]) and row[x + run][2] == colour:
                run += 1
            parts.append(f'<rect x="{x * CELL_W}" y="{y * CELL_H}" '
                         f'width="{run * CELL_W}" height="{CELL_H}" fill="{palette[colour]}"/>')
            x += run

        for x, cell in enumerate(row):
            if not is_map_cell(cell):
                continue
            parts.append(f'<rect x="{x * CELL_W + inset_x}" y="{y * CELL_H + inset_y}" '
                         f'width="{size}" height="{size}" fill="{palette[cell[1]]}"/>')

        # Anything that is not a map cell still has to be drawn, or the panel border either side of
        # the map goes missing and the frame looks broken — which is exactly how it was reported.
        for x, (character, foreground, _) in enumerate(row):
            if character == ' ' or character == MAP_GLYPH:   # squares are already drawn, above
                continue
            fill = palette[foreground] if foreground is not None else '#cccccc'
            glyph = character.replace('&', '&amp;').replace('<', '&lt;')
            parts.append(f'<text x="{x * CELL_W}" y="{y * CELL_H + CELL_H - 2}" '
                         f'font-family="Menlo,monospace" font-size="{CELL_H - 2}" '
                         f'fill="{fill}" xml:space="preserve">{glyph}</text>')
    return ''.join(parts) + '</svg>'


def html(screens, columns, path):
    """Writes the frames out as HTML, which is the only honest way to show a colour display."""
    palette = xterm_palette()
    # 10px in a 0.6-advance monospace face is exactly CELL_W, so the text rows line up with the map.
    parts = ['<!doctype html><meta charset="utf-8"><title>fatrabbit</title>',
             '<style>body{background:#111;color:#ccc;font-family:-apple-system,sans-serif;'
             f'padding:24px}}pre{{font-family:"SF Mono",Menlo,monospace;font-size:10px;'
             f'line-height:{CELL_H}px;letter-spacing:0;background:#000;padding:14px;'
             'border-radius:6px;overflow-x:auto;display:inline-block;margin:0}'
             'svg{display:block}h2{font-weight:500;font-size:15px;margin:28px 0 8px}</style>']

    for label, screen in screens:
        parts.append(f'<h2>{label}</h2><pre>')
        pendingMap = []
        for row in screen.cells:
            if is_map_row(row):
                pendingMap.append(row)
                continue
            if pendingMap:
                parts.append(svg(pendingMap, columns, palette))
                pendingMap = []
            line = ''
            run = None
            for character, foreground, background in row:
                key = (foreground, background)
                if key != run:
                    if run is not None:
                        line += '</span>'
                    style = ''
                    if foreground is not None:
                        style += f'color:{palette[foreground]};'
                    if background is not None:
                        style += f'background:{palette[background]};'
                    line += f'<span style="{style}">'
                    run = key
                line += (character.replace('&', '&amp;').replace('<', '&lt;')
                         if character != ' ' else '&nbsp;')
            if run is not None:
                line += '</span>'
            parts.append(line + '\n')
        if pendingMap:
            parts.append(svg(pendingMap, columns, palette))
        parts.append('</pre>')

    with open(path, 'w') as handle:
        handle.write(''.join(parts))


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    path, columns, rows = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    wanted = int(sys.argv[4]) if len(sys.argv) > 4 else None
    data = open(path, 'rb').read()

    # --html <file> <frame>,<frame>,… renders several frames side by side, in colour.
    if '--html' in sys.argv:
        at = sys.argv.index('--html')
        target = sys.argv[at + 1]
        numbers = [int(n) for n in sys.argv[at + 2].split(',')]
        _, _, _, _, kept = replay(data, columns, rows, None, keep=set(numbers))
        screens = [(f'frame {number}', kept[number]) for number in numbers if number in kept]
        html(screens, columns, target)
        print(f'wrote {target}')
        raise SystemExit(0)

    frames, (text, census, letters), left, overruns, _ = replay(data, columns, rows, wanted)
    print(f'--- {frames} frame(s) in {len(data)} bytes, showing '
          f'{"frame " + str(wanted) if wanted else "the last"} ---')
    print(text)
    print('--- the grid as letters: . free  f/F in place  m/M to move  k/K collected  '
          'n/N written  g/G repointed  s/S parked  X bad, '
          'and where busy: r read  w write  p repoint  c clear ---')
    for line in letters:
        print(line)
    print('--- colours ---')
    for colour, count in sorted(census.items(), key=lambda pair: -pair[1]):
        print(f'  {colour:>4}: {count}')
    print('--- after the alternate screen was left ---')
    if left is None:
        print('  never left it')
    else:
        tail = data[left:].decode('utf-8', 'replace')
        lines = tail.splitlines()
        print(f'  {len(lines)} line(s), {len(tail)} bytes')
        for line in lines[:4]:
            print(f'  | {line}')
        if len(lines) > 8:
            print('  | …')
        for line in lines[-4:]:
            print(f'  | {line}')

    if overruns:
        rows_hit = sorted(set(overruns))
        print(f'--- OVERRUN: {len(overruns)} character(s) past column {columns} on '
              f'row(s) {rows_hit} ---')
        raise SystemExit(1)
    raise SystemExit(0)


if __name__ == '__main__':
    main()
