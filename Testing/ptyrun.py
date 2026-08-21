#!/usr/bin/env python3
"""Runs a command with its output on a real pseudo-terminal, and saves every byte of it.

    python3 ptyrun.py <columns> <rows> <capture-file> <command> [args...]

Needed because the block-map display only appears when stderr is an interactive terminal, which
is exactly what a shell pipeline is not. Redirect its output and you get the line-based fallback —
correct behaviour, and no use at all for checking the display. This hands the command a pty of a
chosen size, so the frames can be captured and replayed by screenshot.py.

Note the window size is set explicitly rather than inherited: the layout is decided by it, and a
capture is only meaningful next to the size it was taken at. TERM and LANG are set too, since the
display consults both before deciding what it can draw.

    python3 ptyrun.py 100 30 run.cap ./fatrabbit -n /tmp/test.img
    python3 screenshot.py run.cap 100 30

Add --interrupt <seconds>[,<seconds>…] before the command to send Ctrl-C after that long. It goes
in as the character, through the terminal, so the signal arrives the way it does from a keyboard
rather than from kill(2) — which is the thing worth testing, since a display has to hand the
terminal back however it is stopped:

    python3 ptyrun.py 100 30 stop.cap --interrupt 20 ./fatrabbit /dev/rdisk4s1
    python3 ptyrun.py 100 30 stop.cap --interrupt 20,21 ./fatrabbit /dev/rdisk4s1
"""

import fcntl
import os
import select
import struct
import sys
import termios
import time


def main():
    if len(sys.argv) < 5:
        raise SystemExit(__doc__)
    columns, rows, capture, rest = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4:]

    interrupts = []
    resizes = []
    while rest and rest[0] in ('--interrupt', '--resize'):
        if rest[0] == '--interrupt':
            interrupts = [float(value) for value in rest[1].split(',')]
        else:
            # <seconds>:<columns>x<rows>, repeatable with commas
            for step in rest[1].split(','):
                when, size = step.split(':')
                wide, high = size.split('x')
                resizes.append((float(when), int(wide), int(high)))
        rest = rest[2:]
    command = rest

    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
    # Defaults, not overrides: a caller testing the fallbacks needs TERM=dumb or NO_COLOR to reach
    # the command rather than being quietly replaced with something that works.
    environment = dict(os.environ)
    environment.setdefault('TERM', 'xterm-256color')
    environment.setdefault('LANG', 'en_GB.UTF-8')

    child = os.fork()
    if child == 0:
        os.close(master)
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        for target in (0, 1, 2):
            os.dup2(slave, target)
        os.close(slave)
        os.execvpe(command[0], command, environment)

    os.close(slave)
    # Chunks are collected and joined at the end, and the prompt is looked for in a small rolling
    # window rather than in everything read so far. Both matter more than they look: appending to a
    # bytes object copies all of it, and scanning the whole buffer per read rescans all of it, so
    # either one turns the reader quadratic. A capture is tens of megabytes, and once the reader
    # falls behind, the pty's buffer fills, the tool blocks writing to it, and the run crawls to a
    # halt — a measurement tool bringing the thing it measures to its knees.
    chunks = []
    window = b''
    started = time.monotonic()
    pending = sorted(interrupts)
    pendingResizes = sorted(resizes)
    dismissed = False
    while True:
        # A finished run holds the map on screen until a key is pressed, so an unattended capture
        # would wait for ever. Watching for the prompt and answering it keeps captures automatic and
        # exercises that path at the same time.
        if not dismissed and b'press any key' in window:
            dismissed = True
            os.write(master, b' ')
        if pending and time.monotonic() - started >= pending[0]:
            os.write(master, b'\x03')
            print(f'sent Ctrl-C at {pending.pop(0)}s', file=sys.stderr)
        if pendingResizes and time.monotonic() - started >= pendingResizes[0][0]:
            when, wide, high = pendingResizes.pop(0)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', high, wide, 0, 0))
            print(f'resized to {wide}x{high} at {when}s', file=sys.stderr)
        readable, _, _ = select.select([master], [], [], 0.2)
        if not readable:
            continue
        try:
            chunk = os.read(master, 1 << 16)
        except OSError:                     # the child has gone and the pty has hung up
            break
        if not chunk:
            break
        chunks.append(chunk)
        window = (window + chunk)[-4096:]

    _, status = os.waitpid(child, 0)
    data = b''.join(chunks)
    with open(capture, 'wb') as handle:
        handle.write(data)
    code = os.waitstatus_to_exitcode(status)
    print(f'{len(data)} bytes captured, exit {code}', file=sys.stderr)
    raise SystemExit(0 if code == 0 else code)


main()
