#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Apex Code's own memory, as E0 counted it: gnome-builder's process tree, its language servers and podman exec clients apart;
# and the host side of the toolbox runtime ("glue"): those clients, apex-toolbox-exec, the bridge and exec sessions' conmon.
import json, os, re, sys

LSP = re.compile(r'rust-analyzer|typescript-language-server|tsserver|typingsInstaller|pylsp|jedi|ruff|clangd')
GLUE = re.compile(r'^(podman|conmon|\S*apex-toolbox-exec) ')
SESSION = re.compile(r'^(conmon .*--exec\b|\S*apex-toolbox-bridge )')


def cmdline(pid):
    return open(f'/proc/{pid}/cmdline').read().replace('\0', ' ').strip()


def children():
    kids = {}
    for p in filter(str.isdigit, os.listdir('/proc')):
        try:
            ppid = int(open(f'/proc/{p}/stat').read().rsplit(')', 1)[1].split()[1])
        except OSError:
            continue
        kids.setdefault(ppid, []).append(int(p))
    return kids


def rollup(pid):
    out = {}
    for line in open(f'/proc/{pid}/smaps_rollup'):
        key, _, rest = line.partition(':')
        if key in ('Rss', 'Pss'):
            out[key.lower()] = int(rest.split()[0])
    return out


def add(into, pid):
    m = rollup(pid)
    into['rss'] += m['rss']
    into['pss'] += m['pss']
    into['n'] += 1


def main(root):
    kids, total, apart, stack = children(), {'rss': 0, 'pss': 0, 'n': 0}, [], [root]
    glue, seen = {'rss': 0, 'pss': 0, 'n': 0}, set()
    while stack:
        pid = stack.pop()
        try:
            cmd = cmdline(pid)
            if GLUE.search(cmd):
                apart.append(cmd[:80])
                add(glue, pid)
                seen.add(pid)
                continue
            if LSP.search(cmd):
                apart.append(cmd[:80])
                continue
            m = rollup(pid)
        except OSError:
            continue
        total['rss'] += m['rss']
        total['pss'] += m['pss']
        total['n'] += 1
        stack.extend(kids.get(pid, []))
    # podman detaches each exec session's conmon from the tree; the bridge runs under one.
    for p in filter(str.isdigit, os.listdir('/proc')):
        try:
            if int(p) not in seen and SESSION.search(cmdline(p)):
                add(glue, int(p))
        except OSError:
            continue
    total['apart'] = apart
    total['glue'] = glue
    print(json.dumps(total))


main(int(sys.argv[1]))
