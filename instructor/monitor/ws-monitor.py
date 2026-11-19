#!/usr/bin/env python3
"""Instructor monitor for workshop participants on the bastion.

Tails the terminal recordings in /var/log/ws-sessions/<user>/ (written by
zz-ws-record.sh) and the per-command events written by hook.bash, detects
problems and streams everything to the browser over one Server-Sent Events
connection. Listens on a unix socket so that participants on the same host
cannot reach it; the instructor connects through `ssh -L`.

Python 3.8+, standard library only.
"""

import argparse
import base64
import collections
import json
import os
import pwd
import queue
import re
import socket
import socketserver
import threading
import time
from http.server import BaseHTTPRequestHandler

ROOT = "/var/log/ws-sessions"
EXCLUDE_FILE = "/etc/ws-monitor/exclude"
STATIC_DIR = os.path.dirname(os.path.abspath(__file__))
BUFFER_CAP = 1_500_000          # bytes of terminal output kept per participant
ALERTS_CAP = 300                # alerts kept per participant
SCAN_INTERVAL = 0.4

ERROR_WINDOW = 180              # tile stays red this long after an error, seconds
STUCK_REPEAT = 3                # same command failing this many times...
STUCK_REPEAT_WINDOW = 600       # ...within this window means "stuck"
STUCK_FAILS = 5                 # or this many problems without a single success...
STUCK_FAILS_WINDOW = 360        # ...within this window
STUCK_COOLDOWN = 300
HUNG_AFTER = 240                # command running this long...
HUNG_SILENT = 180               # ...with no output for this long
IDLE_AFTER = 600                # no output at all for this long
PATTERN_COOLDOWN = 20

INTERACTIVE = {
    "ssh", "virtctl", "vi", "vim", "nano", "less", "more", "man", "top", "htop",
    "watch", "k9s", "tmux", "screen", "bash", "sh", "su", "sudo", "tail", "journalctl",
    "python", "python3", "mc", "telnet", "nc", "psql", "mysql",
}
TRIVIAL = {"cd", "ls", "ll", "clear", "pwd", "history", "echo", "cat", "exit", "whoami"}

ANSI_RE = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")
PROMPT_RE = re.compile(r"^(\S+@[\w.-]+:\S*\s?[$#]|\[\S+@\S+ [^\]]*\][$#])\s")
PATTERNS = [
    ("error", re.compile(r"\berror\b", re.I)),
    ("forbidden", re.compile(r"\bforbidden\b", re.I)),
    ("not found", re.compile(r"\bnot found\b|no such file or directory|command not found", re.I)),
    ("permission denied", re.compile(r"permission denied|unauthorized", re.I)),
    ("connection", re.compile(r"connection refused|connection reset|no route to host|could not resolve", re.I)),
    ("timeout", re.compile(r"timed out|\btimeout\b|deadline exceeded", re.I)),
    ("pod failure", re.compile(r"ImagePullBackOff|ErrImagePull|CrashLoopBackOff|CreateContainerConfigError|OOMKilled")),
    ("failed", re.compile(r"\bfailed\b|\bfatal\b|\bunable to\b|\binvalid\b|\bx509\b", re.I)),
]


MESSAGES = {
    "pattern": "{0}",
    "ok_with_error": "command succeeded, but its output says: {0}\n{1}",
    "exit": "exit {0}: {1}\n{2}",
    "stuck_repeat": "the same command failed {0} times: {1}",
    "stuck_many": "{0} errors in a row without a single successful command",
    "hung": "command running {0} min with no output: {1}",
    "idle": "no activity for {0} min",
}


def now_ms():
    return int(time.time() * 1000)


def first_word(cmd):
    words = cmd.strip().split()
    while words and ("=" in words[0] and not words[0].startswith("=")):
        words = words[1:]          # skip VAR=value prefixes
    return words[0] if words else ""


def normalize(cmd):
    return " ".join(cmd.split())


class Participant:
    def __init__(self, name):
        self.name = name
        self.offsets = {}               # path -> bytes read
        self.buf = bytearray()
        self.base = 0                   # absolute position of buf[0]
        self.total = 0                  # absolute position after the last byte
        self.carry = b""                # unfinished line for pattern matching
        self.alerts = collections.deque(maxlen=ALERTS_CAP)
        self.last_out = 0
        self.last_ok = 0
        self.running = None             # {"cmd", "since"}
        self.fails = collections.deque(maxlen=50)      # (ts, normalized cmd)
        self.problems = collections.deque(maxlen=100)  # ts of any failure or pattern hit
        self.pattern_last = {}
        self.stuck_at = 0
        self.stuck_acked = True
        self.hung_for = None
        self.idle_flag = False
        self.online = False
        self.acked_at = 0
        self.clock = 0                  # best known time of the data being read (for replay)
        self.marks = collections.deque(maxlen=ALERTS_CAP * 2)  # line markers: {"id", "pos", "back"}
        self.cmd_hit = None             # (error line, mark id) seen while the current command runs

    def level(self, t):
        if not self.stuck_acked:
            return "stuck"
        recent = [a for a in self.alerts if a["sev"] == "error" and a["ts"] > max(self.acked_at, t - ERROR_WINDOW * 1000)]
        if recent:
            return "error"
        if self.hung_for or self.idle_flag:
            return "warn"
        return "ok"

    def state(self, t):
        errors = sum(1 for a in self.alerts if a["sev"] == "error" and a["ts"] > max(self.acked_at, t - 600_000))
        return {
            "level": self.level(t),
            "running": self.running,
            "errors": errors,
            "lastOut": self.last_out,
            "online": self.online,
        }


class Monitor:
    def __init__(self, root):
        self.root = root
        self.lock = threading.Lock()
        self.users = {}
        self.subscribers = set()
        self.alert_seq = 0
        self.mark_seq = 0
        self.live = False               # False while replaying history at startup
        self.last_states = {}
        self.online_checked = 0

    # ---- broadcasting -------------------------------------------------
    def publish(self, msg):
        dead = []
        for q in self.subscribers:
            try:
                q.put_nowait(msg)
            except queue.Full:
                dead.append(q)
        for q in dead:
            self.subscribers.discard(q)

    def subscribe(self):
        q = queue.Queue(maxsize=20000)
        with self.lock:
            t = now_ms()
            q.put({"t": "users", "list": sorted(self.users, key=natural_key)})
            for name in sorted(self.users, key=natural_key):
                p = self.users[name]
                pos = p.base
                for m in p.marks:
                    if m["pos"] < p.base:
                        continue
                    if m["pos"] > pos:
                        q.put(out_msg(name, p.buf[pos - p.base:m["pos"] - p.base]))
                        pos = m["pos"]
                    q.put(dict(m, t="mark", u=name))
                if p.total > pos:
                    q.put(out_msg(name, p.buf[pos - p.base:]))
                for a in p.alerts:
                    q.put(dict(a, t="alert", u=name, replay=True))
                q.put({"t": "state", "u": name, "s": p.state(t)})
            q.put({"t": "ready"})
            self.subscribers.add(q)
        return q

    def unsubscribe(self, q):
        with self.lock:
            self.subscribers.discard(q)

    # ---- alerts -------------------------------------------------------
    def new_mark(self, p, back):
        """Marks the terminal line `back` rows above the current end of output."""
        self.mark_seq += 1
        m = {"id": self.mark_seq, "pos": p.total, "back": back}
        p.marks.append(m)
        if self.live:
            self.publish(dict(m, t="mark", u=p.name))
        return m["id"]

    def alert(self, p, kind, sev, key, args, ts=None, mark=None):
        """`key` + `args` let the page render the message in its own language; `msg` is the English text."""
        self.alert_seq += 1
        args = [a[:300] if isinstance(a, str) else a for a in args]
        a = {"id": self.alert_seq, "ts": ts or now_ms(), "kind": kind, "sev": sev,
             "key": key, "args": args, "msg": MESSAGES[key].format(*args).rstrip(), "mark": mark}
        p.alerts.append(a)
        if self.live:
            self.publish(dict(a, t="alert", u=p.name, replay=False))

    def ack(self, name):
        with self.lock:
            p = self.users.get(name)
            if not p:
                return
            p.stuck_acked = True
            p.acked_at = now_ms()
            p.fails.clear()
            p.problems.clear()
            self.push_state(p, force=True)

    def push_state(self, p, force=False):
        s = p.state(now_ms())
        if force or self.last_states.get(p.name) != s:
            self.last_states[p.name] = s
            if self.live:
                self.publish({"t": "state", "u": p.name, "s": s})

    # ---- scanning -----------------------------------------------------
    def excluded(self):
        try:
            with open(EXCLUDE_FILE) as f:
                return {line.strip() for line in f if line.strip()}
        except OSError:
            return set()

    def scan(self):
        try:
            names = [n for n in os.listdir(self.root) if os.path.isdir(os.path.join(self.root, n))]
        except OSError:
            return
        skip = self.excluded()
        with self.lock:
            added = False
            for name in names:
                if name in skip:
                    continue
                if name not in self.users:
                    self.users[name] = Participant(name)
                    added = True
                self.scan_user(self.users[name])
            if added and self.live:
                self.publish({"t": "users", "list": sorted(self.users, key=natural_key)})
            t = now_ms()
            if t - self.online_checked > 3000:
                self.online_checked = t
                alive = recording_users()
                for p in self.users.values():
                    p.online = p.name in alive
            for p in self.users.values():
                self.check_timers(p, t)
                self.push_state(p)

    def scan_user(self, p):
        d = os.path.join(self.root, p.name)
        try:
            files = sorted(f for f in os.listdir(d) if f.endswith(".log"))
        except OSError:
            return
        for f in files:
            path = os.path.join(d, f)
            first = path not in p.offsets
            data = read_new(path, p.offsets)
            if first:
                started = f[:15].replace("-", " ")
                p.clock = max(p.clock, session_ms(f))
                self.append(p, ("\r\n\x1b[2;36m──── %s ────\x1b[0m\r\n" % fmt_session(started)).encode())
            ev = path + ".events"
            events = read_new(ev, p.offsets).decode("utf-8", "replace").splitlines() if os.path.exists(ev) else []
            # Within one scan a command usually starts, prints and ends: apply starts first so that
            # error lines are attributed to the running command instead of raising a second alert.
            split = len(events)
            for i, line in enumerate(events):
                if "\tE\t" in line:
                    split = i
                    break
            for line in events[:split]:
                self.on_event(p, line)
            if data:
                self.append(p, data)
            for line in events[split:]:
                self.on_event(p, line)

    def append(self, p, data):
        p.buf += data
        p.total += len(data)
        if len(p.buf) > BUFFER_CAP:
            cut = len(p.buf) - BUFFER_CAP
            del p.buf[:cut]
            p.base += cut
        p.last_out = now_ms() if self.live else p.last_out
        p.idle_flag = False
        if self.live:
            self.publish(out_msg(p.name, data))
        self.match_patterns(p, data)

    def match_patterns(self, p, data):
        text = p.carry + data
        lines = text.split(b"\n")
        p.carry = lines.pop()[-4000:]
        k = len(lines)
        t = now_ms() if self.live else p.clock
        for i, raw in enumerate(lines):
            line = ANSI_RE.sub(b"", raw).decode("utf-8", "replace")
            line = line.split("\r")[-1] if line.rstrip("\r").count("\r") else line.rstrip("\r")
            line = line.strip()
            if not line or PROMPT_RE.match(line + " "):
                continue
            for label, rx in PATTERNS:
                if not rx.search(line):
                    continue
                r = p.running
                if r and first_word(r["cmd"]) not in INTERACTIVE:
                    # The exit code will tell whether it failed; keep the first error line for that alert.
                    if not p.cmd_hit:
                        p.cmd_hit = (line, self.new_mark(p, k - i))
                elif t - p.pattern_last.get(label, 0) > PATTERN_COOLDOWN * 1000:
                    p.pattern_last[label] = t
                    p.problems.append(t)
                    self.alert(p, "pattern", "error", "pattern", [line], ts=t, mark=self.new_mark(p, k - i))
                    self.check_stuck(p, t)
                break

    def on_event(self, p, line):
        parts = line.split("\t", 2)
        if len(parts) < 3 or not parts[0].isdigit():
            return
        ts, kind, val = int(parts[0]), parts[1], parts[2]
        p.clock = max(p.clock, ts)
        if kind == "S":
            if first_word(val) in ("exit", "logout"):
                return
            p.running = {"cmd": val, "since": ts}
            p.hung_for = None
            p.cmd_hit = None
            return
        if kind != "E" or not p.running:
            return
        cmd, rc = p.running["cmd"], int(val) if val.lstrip("-").isdigit() else 0
        hit, p.cmd_hit = p.cmd_hit, None
        p.running = None
        p.hung_for = None
        word = first_word(cmd)
        if rc in (130, 148) or word in INTERACTIVE:
            return
        if rc == 0:
            if word not in TRIVIAL:
                p.last_ok = ts
            if hit:
                self.alert(p, "pattern", "warn", "ok_with_error", [hit[0], cmd], ts=ts, mark=hit[1])
            return
        p.fails.append((ts, normalize(cmd)))
        p.problems.append(ts)
        mark = hit[1] if hit else (self.new_mark(p, 1) if self.live else None)
        self.alert(p, "fail", "error", "exit", [rc, cmd, hit[0] if hit else ""], ts=ts, mark=mark)
        self.check_stuck(p, ts)

    def check_stuck(self, p, t):
        if t - p.stuck_at < STUCK_COOLDOWN * 1000 and p.stuck_at:
            return
        reason = None
        if p.fails:
            last_cmd = p.fails[-1][1]
            same = [1 for ts, c in p.fails if c == last_cmd and ts > t - STUCK_REPEAT_WINDOW * 1000 and ts > p.last_ok]
            if len(same) >= STUCK_REPEAT:
                reason = ("stuck_repeat", [len(same), last_cmd])
        if not reason:
            since = max(t - STUCK_FAILS_WINDOW * 1000, p.last_ok, p.acked_at)
            n = sum(1 for ts in p.problems if ts > since)
            if n >= STUCK_FAILS:
                reason = ("stuck_many", [n])
        if reason:
            p.stuck_at = t
            p.stuck_acked = False
            self.alert(p, "stuck", "stuck", reason[0], reason[1], ts=t)

    def check_timers(self, p, t):
        if not self.live:
            return
        if not p.online:
            p.running = None
            p.hung_for = None
            p.idle_flag = False
            return
        r = p.running
        if r and first_word(r["cmd"]) not in INTERACTIVE and not p.hung_for:
            if t - r["since"] > HUNG_AFTER * 1000 and t - p.last_out > HUNG_SILENT * 1000:
                p.hung_for = r["since"]
                self.alert(p, "hung", "warn", "hung", [(t - r["since"]) // 60000, r["cmd"]])
        if p.online and p.last_out and not p.idle_flag and t - p.last_out > IDLE_AFTER * 1000:
            p.idle_flag = True
            self.alert(p, "idle", "warn", "idle", [(t - p.last_out) // 60000])

    def run(self):
        self.scan()                     # replay everything recorded so far, silently
        t = now_ms()
        for p in self.users.values():
            p.last_out = p.last_out or t
            if p.stuck_at and t - p.stuck_at > 3_600_000:
                p.stuck_acked = True
        self.live = True
        while True:
            time.sleep(SCAN_INTERVAL)
            try:
                self.scan()
            except Exception as e:      # keep the monitor alive on odd files
                print("scan error:", repr(e), flush=True)


def read_new(path, offsets):
    pos = offsets.get(path, 0)
    try:
        size = os.path.getsize(path)
        if size < pos:
            pos = 0
        if size == pos:
            offsets[path] = pos
            return b""
        with open(path, "rb") as f:
            f.seek(pos)
            data = f.read(4_000_000)
    except OSError:
        return b""
    offsets[path] = pos + len(data)
    return data


def recording_users():
    """Users that currently have a live `script` recorder, i.e. are logged in."""
    users = set()
    if not os.path.isdir("/proc"):
        return users
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open("/proc/%s/comm" % pid) as f:
                if f.read().strip() != "script":
                    continue
            users.add(pwd.getpwuid(os.stat("/proc/" + pid).st_uid).pw_name)
        except (OSError, KeyError):
            continue
    return users


def session_ms(fname):
    try:
        return int(time.mktime(time.strptime(fname[:15], "%Y%m%d-%H%M%S")) * 1000)
    except ValueError:
        return 0


def fmt_session(s):
    # "20261119 093222" -> "19.11 09:32"
    try:
        return "%s.%s %s:%s" % (s[6:8], s[4:6], s[9:11], s[11:13])
    except IndexError:
        return s


def out_msg(name, data):
    return {"t": "out", "u": name, "d": base64.b64encode(bytes(data)).decode()}


def natural_key(s):
    return [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", s)]


class Handler(BaseHTTPRequestHandler):
    monitor = None
    protocol_version = "HTTP/1.1"

    def address_string(self):
        return "local"

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            return self.static("index.html", "text/html; charset=utf-8")
        if path == "/stream":
            return self.stream()
        self.send_error(404)

    def do_POST(self):
        path, _, qs = self.path.partition("?")
        if path == "/ack":
            name = dict(kv.split("=", 1) for kv in qs.split("&") if "=" in kv).get("u", "")
            self.monitor.ack(name)
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_error(404)

    def static(self, name, ctype):
        with open(os.path.join(STATIC_DIR, name), "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        q = self.monitor.subscribe()
        try:
            while True:
                try:
                    msg = q.get(timeout=15)
                    batch = [msg]
                    while len(batch) < 500:
                        try:
                            batch.append(q.get_nowait())
                        except queue.Empty:
                            break
                    payload = "".join("data: %s\n\n" % json.dumps(m, ensure_ascii=False) for m in batch)
                    self.wfile.write(payload.encode())
                except queue.Empty:
                    self.wfile.write(b": ping\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            self.monitor.unsubscribe(q)


class UnixHTTPServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class TCPHTTPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=ROOT)
    ap.add_argument("--socket", default="/run/ws-monitor/monitor.sock")
    ap.add_argument("--socket-owner", default="ubuntu")
    ap.add_argument("--tcp", help="host:port instead of a unix socket (testing only)")
    args = ap.parse_args()

    mon = Monitor(args.root)
    Handler.monitor = mon
    threading.Thread(target=mon.run, daemon=True).start()

    if args.tcp:
        host, port = args.tcp.rsplit(":", 1)
        srv = TCPHTTPServer((host, int(port)), Handler)
    else:
        os.makedirs(os.path.dirname(args.socket), exist_ok=True)
        if os.path.exists(args.socket):
            os.unlink(args.socket)
        old = os.umask(0o177)
        srv = UnixHTTPServer(args.socket, Handler)
        os.umask(old)
        pw = pwd.getpwnam(args.socket_owner)
        os.chown(args.socket, pw.pw_uid, pw.pw_gid)
        os.chmod(args.socket, 0o600)
    print("ws-monitor listening on", args.tcp or args.socket, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
