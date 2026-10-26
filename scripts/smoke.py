#!/usr/bin/env python3
"""End-to-end smoke tests: run the real binaries in a pseudo-terminal.

Needs: python3 with `pyte` (pip install pyte), binaries in ./bin (./build.sh).
Exit status is non-zero if any check fails.
"""
import os, pty, select, signal, struct, fcntl, termios, time, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
import pyte

KEYS = {'up': b'\x1b[A', 'down': b'\x1b[B', 'right': b'\x1b[C', 'left': b'\x1b[D', 'enter': b'\r',
        'esc': b'\x1b', 'tab': b'\t', 'ctrl-c': b'\x03', 'ctrl-z': b'\x1a', 'space': b' '}


class Pty:
    def __init__(self, argv, cols=100, rows=30, env=None, answers=None):
        self.cols, self.rows = cols, rows
        self.out = bytearray()
        self.answers = answers  # bytes to send back when the app probes (DA1 seen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update({'TERM': 'xterm-256color', 'COLORTERM': 'truecolor'})
            os.environ.pop('NO_COLOR', None)
            if env: os.environ.update(env)
            os.execvp(argv[0], argv)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    def pump(self, ms):
        end = time.time() + ms / 1000
        while (t := end - time.time()) > 0:
            r, _, _ = select.select([self.fd], [], [], t)
            if r:
                try: d = os.read(self.fd, 65536)
                except OSError: return
                if not d: return
                self.out.extend(d)
                if self.answers and b'\x1b[c' in self.out:
                    os.write(self.fd, self.answers); self.answers = None

    def send(self, data, settle=60):
        if isinstance(data, str): data = data.encode()
        while data:
            try: n = os.write(self.fd, data[:512])
            except BlockingIOError: n = 0
            data = data[n:]
            self.pump(5)
        self.pump(settle)

    def key(self, name, settle=60): self.send(KEYS[name], settle)

    def wait_for(self, text, timeout=8.0):
        end = time.time() + timeout
        while time.time() < end:
            if text in self.screen(): return True
            self.pump(50)
        return False

    def screen(self):
        scr = pyte.Screen(self.cols, self.rows)
        pyte.ByteStream(scr).feed(bytes(self.out))
        return '\n'.join(l.rstrip() for l in scr.display)

    def exited(self, timeout=3.0):
        end = time.time() + timeout
        while time.time() < end:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid: return os.waitstatus_to_exitcode(status)
            self.pump(50)
        return None

    def kill(self):
        # Keep reading while we wait: on macOS a dying process can block in
        # exit until its unread tty output drains, and a bare waitpid(pid, 0)
        # would then wait forever. Closing the master releases it.
        try: os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        end = time.time() + 5
        while time.time() < end:
            try: pid, _ = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError: break
            if pid: break
            self.pump(20)
        try: os.close(self.fd)
        except OSError: pass


failures = []

def check(name, ok, detail=''):
    print(('  ok   ' if ok else '  FAIL ') + name + ('' if ok else f'  -- {detail}'))
    if not ok: failures.append(name)


def smoke_hello():
    p = Pty(['./bin/hello'], 60, 16)
    check('hello starts', p.wait_for('counter'), p.screen())
    p.key('up'); p.key('up'); p.send('+')
    check('hello counts keys', p.wait_for('3'), p.screen())
    p.send('q')
    check('hello quits cleanly', p.exited() == 0)
    check('hello restores the screen', b'\x1b[?1049l' in p.out)
    p.kill()


def smoke_mission():
    p = Pty(['./bin/mission'], 140, 38)
    check('mission dashboard renders', p.wait_for('BEINGS IN AVATAR'), p.screen()[:500])
    p.key('tab'); p.send('status?'); p.key('enter')
    check('mission chat echoes', p.wait_for('you: status?'))
    p.pump(1600)  # the reply comes from a worker thread after ~0.5-1 s
    after = p.screen().split('you: status?')[-1]
    check('mission threaded reply arrives', any(n + ':' in after for n in ('Sophia', 'Grok', 'Chief', 'BigWednesday')), after)
    p.key('esc'); p.send('2')
    check('mission components tab', p.wait_for('TONES'))
    p.send('3')
    check('mission docs tab', p.wait_for('README.md'))
    p.send('t')
    check('mission theme switch', p.wait_for('daybreak'))
    fcntl.ioctl(p.fd, termios.TIOCSWINSZ, struct.pack('HHHH', 28, 96, 0, 0)); p.cols, p.rows = 96, 28
    p.send('1', 400)
    check('mission reflows on resize', p.wait_for('96×28'))
    p.send('q')
    check('mission quits', p.exited() == 0)
    p.kill()


def shell_script(body):
    f = tempfile.NamedTemporaryFile('w', suffix='.sh', delete=False, dir=None)
    f.write('#!/bin/sh\ncd "%s"\n%s\n' % (ROOT, body)); f.close()
    os.chmod(f.name, 0o755)
    return f.name


def smoke_cli():
    out = tempfile.mktemp()
    script = shell_script(f'''
r=$(./bin/galdr pick --header Letters a b c); echo "pick=[$r] $?" >> {out}
r=$(./bin/galdr enter --header Name --placeholder x); echo "enter=[$r] $?" >> {out}
./bin/galdr approve "Sure?"; echo "approve=$?" >> {out}
./bin/galdr approve "Again?"; echo "cancel=$?" >> {out}
''')
    # Wait for each prompt to be on screen before typing: a freshly built
    # binary can take a while to start, and keys sent before raw mode are lost.
    p = Pty([script], 80, 12)
    p.wait_for('Letters')
    p.key('down'); p.key('down'); p.key('enter')
    p.wait_for('Name')
    p.send('hello world'); p.key('enter')
    p.wait_for('Sure?')
    p.key('right'); p.key('enter')
    p.wait_for('Again?')
    p.key('esc', 600)
    p.exited(5); p.kill()
    got = open(out).read() if os.path.exists(out) else ''
    check('cli pick', 'pick=[c] 0' in got, got)
    check('cli enter', 'enter=[hello world] 0' in got, got)
    check('cli approve no', 'approve=1' in got, got)
    check('cli cancel is 130', 'cancel=130' in got, got)

    out3 = tempfile.mktemp()
    script3 = shell_script(f'''
r=$(printf 'alpha\\nbeta\\ngamma\\n' | ./bin/galdr refine --header Greek); echo "refine=[$r] $?" >> {out3}
r=$(./bin/galdr draft --header Notes); echo "draft=[$r] $?" >> {out3}
''')
    p = Pty([script3], 80, 14)
    p.wait_for('Greek')
    p.send('gam'); p.key('enter')
    p.wait_for('Notes')
    p.send('line one'); p.key('enter'); p.send('line two'); p.send(b'\x04', 600)
    p.exited(5); p.kill()
    got = open(out3).read() if os.path.exists(out3) else ''
    check('cli refine', 'refine=[gamma] 0' in got, got)
    check('cli draft (ctrl+d saves)', 'draft=[line one\nline two] 0' in got, got)

    big = 'x' * 12000
    out2 = tempfile.mktemp()
    p = Pty([shell_script(f'./bin/galdr enter --header Paste > {out2}; echo "exit=$?" >> {out2}')], 80, 5)
    p.wait_for('Paste')
    p.send(b'\x1b[200~' + big.encode() + b'\x1b[201~', 300); p.key('enter', 800)
    p.exited(5); p.kill()
    got = open(out2).read().splitlines() if os.path.exists(out2) else []
    check('cli 12k paste intact', bool(got) and got[0] == big, f'{len(got[0]) if got else 0} chars')

    def run(args, env=None):
        e = dict(os.environ, **(env or {}))
        r = subprocess.run(['./bin/galdr'] + args, capture_output=True, text=True,
                           start_new_session=True, stdin=subprocess.DEVNULL, env=e)
        return r.returncode, r.stdout.strip()
    check('cli no-tty needs a default', run(['approve', 'x'])[0] == 2)
    check('cli no-tty --default', run(['approve', '--default', 'no', 'x'])[0] == 1)
    check('cli no-tty --selected', run(['pick', '--selected', 'b', 'a', 'b']) == (0, 'b'))
    code, text = run(['design', 'plain'])
    check('cli design is plain when piped', code == 0 and '\x1b' not in text and 'plain' in text, repr(text))
    code, text = run(['--help'])
    check('cli --help prints to stdout and succeeds', code == 0 and 'galdr pick' in text, repr((code, text[:80])))
    check('cli rejects an unknown flag', run(['design', '--bogus', 'hi', 'there'])[0] == 2)


def smoke_degradation():
    p = Pty(['./bin/mission'], 120, 32, env={'NO_COLOR': '1'})
    p.wait_for('BEINGS')
    raw = bytes(p.out)
    check('NO_COLOR emits no colors', b'38;2;' not in raw and b'48;2;' not in raw and b'38;5;' not in raw)
    p.send('q'); p.exited(); p.kill()

    out = tempfile.mktemp()
    p = Pty([shell_script(f'export TERM=dumb; r=$(./bin/galdr pick a b); echo "[$r] $?" >> {out}')], 60, 10)
    check('TERM=dumb pick asks "Pick [1-2]"', p.wait_for('Pick [1-2]'), p.screen())
    p.send('2'); p.key('enter', 600)
    p.exited(3); p.kill()
    got = open(out).read() if os.path.exists(out) else ''
    check('TERM=dumb line prompt', '[b] 0' in got, got)


def smoke_plain_sanitized():
    # Audit A3: plain prompts draw with raw writes (no Frame sanitizer), so
    # untrusted headers/items/questions must be sanitized on that path. The
    # prompt region of the captured bytes must contain no control sequences.
    evil = 'safe\x1b[2Jspoof\x07bell\u009b31m'
    p = Pty([shell_script(f'''
export TERM=dumb
./bin/galdr pick --header "H\x1b]0;pwned\x07x" '{evil}' ok
''')], 60, 10)
    check('plain prompt appears', p.wait_for('Pick [1-2]'), p.screen())
    p.kill()
    prompt_region = bytes(p.out).split(b'Pick [1-2]')[0] if b'Pick [1-2]' in bytes(p.out) else bytes(p.out)
    check('plain prompts strip ESC/BEL/OSC/C1 from untrusted text',
          b'\x1b' not in prompt_region and b'\x07' not in prompt_region and b'\x9b' not in prompt_region,
          repr(prompt_region[-80:]))
    check('plain prompt keeps the readable text', b'safe[2Jspoofbell31mok' in prompt_region.replace(b'  1) ', b'').replace(b'  2) ', b'') or b'spoof' in prompt_region,
          repr(prompt_region))

    q = 'Deploy\x1b[2Jnow?'
    out = tempfile.mktemp()
    p = Pty([shell_script(f'export TERM=dumb; ./bin/galdr approve "{q}" ; echo "exit=$?" >> {out}')], 60, 8)
    p.wait_for('now?')
    prompt_region = bytes(p.out).split(b'[y/N]')[0]
    check('plain approve strips escapes from the question', b'\x1b' not in prompt_region, repr(prompt_region[-60:]))
    p.send('n'); p.key('enter', 600); p.exited(3); p.kill()
    got = open(out).read() if os.path.exists(out) else ''
    check('plain approve still answers', 'exit=1' in got, got)


def smoke_cli_validation():
    # Audit A4: invalid --default values are usage errors, never implicit
    # consent; missing flag values and malformed numbers are errors too.
    def run(args):
        r = subprocess.run(['./bin/galdr'] + args, capture_output=True, text=True,
                           start_new_session=True, stdin=subprocess.DEVNULL, timeout=5)
        return r.returncode, r.stderr.strip()

    cases = [
        (['approve', '--default', 'typo', 'q'], 2, 'invalid approve default'),
        (['approve', '--default', 'yes', 'q'], 0, 'approve yes'),
        (['approve', '--default', 'no', 'q'], 1, 'approve no'),
        (['design', 'hello', '--width'], 2, 'missing flag value'),
        (['design', '--width', 'oops', 'hello'], 2, 'malformed integer'),
        (['design', '--width', '0', 'hello'], 2, 'width below range'),
        (['design', '--pad', 'x', 'hello'], 2, 'malformed pad'),
        (['design', 'hello'], 0, 'valid design still passes'),
    ]
    for args, want, label in cases:
        code, err = run(args)
        check(f'cli validation: {label}', code == want, f'exit {code}, want {want}: {err[:80]}')


def smoke_suspend():
    p = Pty(['bash', '--norc', '--noprofile', '-i'], 60, 14, env={'PS1': '$ '})
    p.pump(400)
    p.send('cd "%s" && ./bin/hello\r' % ROOT, 200)
    check('suspend: app starts under a shell', p.wait_for('counter'))
    p.send('+'); p.key('ctrl-z', 500)
    check('suspend: shell reports Stopped', b'Stopped' in p.out)
    p.send('echo SHELL_HAS_TTY\r', 300)
    check('suspend: shell has the terminal', p.out.count(b'SHELL_HAS_TTY') >= 2)
    p.send('fg\r', 600); p.send('+', 300)
    check('suspend: resumes with state', p.wait_for('2'))
    p.send('q', 300); p.send('exit\r', 300); p.kill()


def smoke_probe():
    modern = (b'\x1b[?1u' b'\x1b[?2026;2$y' b'\x1b[?2027;2$y' b'\x1b]11;rgb:1010/1010/1818\x1b\\'
              b'\x1bP>|FakeTerm 1.0\x1b\\' b'\x1b[?62;22c')
    p = Pty(['./bin/hello'], 60, 16, answers=modern)
    check('probe: app starts with a modern terminal', p.wait_for('counter'))
    raw = bytes(p.out)
    check('probe: enables grapheme clustering (2027)', b'\x1b[?2027h' in raw)
    check('probe: pushes kitty keyboard only when supported', b'\x1b[>1u' in raw)
    p.send('q'); p.exited()
    check('probe: restores 2027 and kitty on exit', b'\x1b[?2027l' in p.out and b'\x1b[<u' in p.out)
    p.kill()

    # pyte answers nothing: the probe times out and nothing optional is enabled.
    start = time.time()
    p = Pty(['./bin/hello'], 60, 16)
    check('probe: silent terminal still starts', p.wait_for('counter'))
    raw = bytes(p.out)
    check('probe: no kitty push without a reply', b'\x1b[>1u' not in raw)
    check('probe: no 2027 without a reply', b'\x1b[?2027h' not in raw)
    p.send('q'); p.exited(); p.kill()


def smoke_logging():
    log = tempfile.mktemp(suffix='.log')
    p = Pty(['./bin/hello'], 60, 16, env={'GALDR_LOG': log, 'GALDR_TRACE': '1'})
    p.wait_for('counter'); p.send('+'); p.send('q'); p.exited(); p.kill()
    text = open(log).read() if os.path.exists(log) else ''
    check('logging: GALDR_LOG records the probe', 'terminal:' in text, text[:200])
    check('logging: GALDR_TRACE records loop iterations', 'loop now=' in text)
    check('logging: nothing leaks onto the screen', b'loop now=' not in p.out and b'terminal:' not in p.out)


def smoke_oneshot_widths():
    # herdr (libghostty) clusters emoji: the family is one 2-cell glyph. The
    # one-shot `design` must ask the terminal before measuring.
    family = '\U0001F468\u200D\U0001F469\u200D\U0001F467'
    clustering = b'\x1b[?2027;1$y' b'\x1bP>|libghostty\x1b\\' b'\x1b[?62;22c'
    for label, answers, want in (('clustering terminal', clustering, 2), ('silent terminal', None, 6)):
        p = Pty(['./bin/galdr', 'design', '--color', 'never', '--pad', '0', '--border', 'sharp', family], 40, 6, answers=answers)
        p.exited(4); p.pump(200); p.kill()
        top = next((l for l in bytes(p.out).decode('utf-8', 'replace').splitlines() if '┌' in l), '')
        dashes = top.count('─')
        check(f'design measures emoji like the terminal ({label})', dashes == want, f'{dashes} cells, want {want}: {top!r}')



def smoke_chat_cluster():
    # herdr walk: 👱‍♂️ (ZWJ + ♂ + VS16) must reach the terminal whole, with the
    # text after it untouched. Galdr's bytes are the half we can prove.
    blond = '\U0001F471\u200D\u2642\uFE0F'
    clustering = b'\x1b[?2027;1$y' b'\x1bP>|libghostty\x1b\\' b'\x1b[?62;22c'
    p = Pty(['./bin/mission'], 140, 38, answers=clustering)
    p.wait_for('BEINGS IN AVATAR')
    p.key('tab'); p.send(blond + '日本 é', 300)
    n = len(p.out); p.key('enter'); p.pump(400)
    sent = bytes(p.out[n:]).decode('utf-8', 'replace')
    check('chat keeps a ZWJ emoji whole', (blond + '日本 é') in sent, repr(sent[:300]))
    p.send('q'); p.kill()

def smoke_signals():
    # Audit A5: a session must restore the host's signal dispositions on
    # close, so embedding Galdr doesn't leave our fatal-signal handler
    # (which _exits) installed after the UI closes. The probe checks a fatal
    # signal (SIGTERM) and the suspend signal (SIGTSTP).
    p = Pty(['./bin/session_probe'], 60, 8)
    check('signals: session restores SIGTERM disposition', p.wait_for('SIGTERM restored: true'), p.screen())
    check('signals: session restores SIGTSTP disposition', p.wait_for('SIGTSTP restored: true'), p.screen())
    check('signals: probe exits 0', p.exited() == 0)
    p.kill()


for fn in (smoke_hello, smoke_mission, smoke_cli, smoke_cli_validation, smoke_degradation, smoke_plain_sanitized, smoke_suspend, smoke_probe, smoke_logging, smoke_oneshot_widths, smoke_chat_cluster, smoke_signals):
    print(fn.__name__)
    try: fn()
    except Exception as ex: check(fn.__name__ + ' raised', False, repr(ex))

print(f'\n{"FAILED: " + ", ".join(failures) if failures else "all smoke checks passed"}')
sys.exit(1 if failures else 0)
