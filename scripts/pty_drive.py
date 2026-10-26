#!/usr/bin/env python3
"""Drive a TUI in a real pseudo-terminal and screen-scrape the result.

usage: pty_drive.py [--cols N] [--rows N] [--keys SPEC] [--raw] -- cmd args...
SPEC is a comma list of steps: 'wait:MS', 'text:abc', 'key:up|down|left|right|enter|esc|tab|ctrl-c', 'hex:1b5b41', 'resize:COLSxROWS'
Prints the final screen as reconstructed by pyte if available, else raw bytes.
"""
import os, pty, sys, time, select, struct, fcntl, termios, argparse

KEYS = {'up':b'\x1b[A','down':b'\x1b[B','right':b'\x1b[C','left':b'\x1b[D','enter':b'\r',
        'esc':b'\x1b','tab':b'\t','stab':b'\x1b[Z','ctrl-c':b'\x03','bs':b'\x7f','space':b' '}

ap = argparse.ArgumentParser()
ap.add_argument('--cols', type=int, default=100); ap.add_argument('--rows', type=int, default=30)
ap.add_argument('--keys', default='wait:300'); ap.add_argument('--raw', action='store_true')
ap.add_argument('--stdin', default=None)
ap.add_argument('cmd', nargs=argparse.REMAINDER)
a = ap.parse_args()
cmd = a.cmd[1:] if a.cmd and a.cmd[0] == '--' else a.cmd

pid, fd = pty.fork()
if pid == 0:
    os.environ['COLORTERM'] = 'truecolor'; os.environ['TERM'] = 'xterm-256color'
    if a.stdin is not None:
        r, w = os.pipe(); os.write(w, a.stdin.encode()); os.close(w); os.dup2(r, 0)
    os.execvp(cmd[0], cmd)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', a.rows, a.cols, 0, 0))
out = bytearray()
def send(data):
    # pty queues are small (about 1 KB on macOS): write in pieces, draining output as we go.
    while data:
        try: n = os.write(fd, data[:512])
        except BlockingIOError: n = 0
        data = data[n:]
        pump(5)

def pump(ms):
    end = time.time() + ms/1000
    while True:
        t = end - time.time()
        if t <= 0: break
        r,_,_ = select.select([fd],[],[],t)
        if r:
            try: d = os.read(fd, 65536)
            except OSError: return False
            if not d: return False
            out.extend(d)
    return True
pump(1500)
for step in a.keys.split(','):
    kind, _, val = step.partition(':')
    if kind == 'wait': pump(int(val))
    elif kind == 'text': send(val.encode()); pump(60)
    elif kind == 'key': send(KEYS[val]); pump(60)
    elif kind == 'hex': send(bytes.fromhex(val)); pump(60)
    elif kind == 'sig':
        import signal; os.kill(pid, getattr(signal, 'SIG' + val)); pump(300)
    elif kind == 'state':
        import subprocess; print('state:', subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True).stdout.strip())
    elif kind == 'resize':
        c, r = map(int, val.split('x')); a.cols, a.rows = c, r
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', r, c, 0, 0)); pump(300)
pump(300)
try:
    _, status = os.waitpid(pid, os.WNOHANG)
except ChildProcessError:
    status = 0
if a.raw:
    sys.stdout.write(repr(bytes(out))[:400000]); print()
try:
    import pyte
    scr = pyte.Screen(a.cols, a.rows); st = pyte.ByteStream(scr); st.feed(bytes(out))
    for line in scr.display: print(line.rstrip())
except ImportError:
    print('(pyte not installed; raw bytes:)'); print(repr(bytes(out))[:4000])
print(f'--- bytes={len(out)} exited={"yes status=%d" % (status>>8) if pid and status else "running/0"}')
