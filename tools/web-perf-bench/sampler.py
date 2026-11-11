#!/usr/bin/env python3
"""Sample CPU time and resident memory of one engine's processes, every --interval seconds.

  sampler.py --tree PID --out f.jsonl        every descendant of PID (Chrome: the browser process)
  sampler.py --pids-file p.json --out f.jsonl  {"role": [pid, ...]} re-read each tick (Folio writes it;
                                               WebKit's XPC services are launchd's children, not the app's)
Stops on SIGTERM/SIGINT. One JSON line per tick: {"t": epoch, "p": [[pid, role, cpu_s, rss_mb], ...]}.
"""
import argparse, json, os, re, signal, subprocess, sys, time

ROLE_PATTERNS = [
    (r'--type=renderer', 'renderer'),
    (r'--type=gpu-process', 'gpu'),
    (r'--type=utility.*network', 'network'),
    (r'--type=utility', 'utility'),
    (r'com\.apple\.WebKit\.WebContent', 'renderer'),
    (r'com\.apple\.WebKit\.GPU', 'gpu'),
    (r'com\.apple\.WebKit\.Networking', 'network'),
]


def cpu_seconds(text):
    # ps time: [[dd-]hh:]mm:ss.ss
    days = 0
    if '-' in text:
        d, text = text.split('-', 1)
        days = int(d)
    parts = [float(p) for p in text.split(':')]
    secs = 0.0
    for p in parts:
        secs = secs * 60 + p
    return days * 86400 + secs


def snapshot():
    out = subprocess.run(['ps', '-axo', 'pid=,ppid=,rss=,time=,args='], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        m = re.match(r'\s*(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.*)', line)
        if m:
            pid, ppid, rss, t, args = m.groups()
            rows[int(pid)] = (int(ppid), int(rss) / 1024, cpu_seconds(t), args)
    return rows


def role_of(args, default):
    for pattern, role in ROLE_PATTERNS:
        if re.search(pattern, args):
            return role
    return default


_libc = None


def responsible_for(pid):
    global _libc
    if _libc is None:
        import ctypes
        _libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        _libc.responsibility_get_pid_responsible_for_pid.restype = ctypes.c_int
        _libc.responsibility_get_pid_responsible_for_pid.argtypes = [ctypes.c_int]
    return _libc.responsibility_get_pid_responsible_for_pid(pid)


def tree(rows, root):
    found, frontier = {root}, [root]
    while frontier:
        parent = frontier.pop()
        for pid, row in rows.items():
            if row[0] == parent and pid not in found:
                found.add(pid)
                frontier.append(pid)
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tree', type=int)
    ap.add_argument('--pids-file')
    ap.add_argument('--responsible', type=int, help='every process macOS holds PID responsible for (WebKit XPC services)')
    ap.add_argument('--out', required=True)
    ap.add_argument('--interval', type=float, default=0.25)
    a = ap.parse_args()
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    signal.signal(signal.SIGINT, lambda *_: stop.append(1))
    with open(a.out, 'a') as f:
        while not stop:
            rows = snapshot()
            procs = []
            if a.tree:
                for pid in tree(rows, a.tree):
                    if pid in rows:
                        ppid, rss, cpu, args = rows[pid]
                        procs.append([pid, 'host' if pid == a.tree else role_of(args, 'other'), cpu, round(rss, 1)])
            elif a.responsible:
                for pid, (ppid, rss, cpu, args) in rows.items():
                    if pid == a.responsible:
                        procs.append([pid, 'host', cpu, round(rss, 1)])
                    elif responsible_for(pid) == a.responsible:
                        procs.append([pid, role_of(args, 'other'), cpu, round(rss, 1)])
            elif a.pids_file:
                try:
                    roles = json.load(open(a.pids_file))
                except (OSError, ValueError):
                    roles = {}
                for role, pids in roles.items():
                    for pid in pids:
                        if pid in rows:
                            procs.append([pid, role, rows[pid][2], round(rows[pid][1], 1)])
            f.write(json.dumps({'t': time.time(), 'p': procs}) + '\n')
            f.flush()
            time.sleep(a.interval)


if __name__ == '__main__':
    sys.exit(main())
