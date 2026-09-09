#!/usr/bin/env python3
"""Deterministic drift tool for the `sync-mea-engine` skill.

Compares the Swift ME-firmware port (DumpCompare/Packages/MEFirmware) against
upstream platomav/MEAnalyzer (a local git clone of the Python parser) and
classifies every change into data / code-added / code-changed / code-removed /
noise.

Data is NOT synced here: the Swift module fetches MEA.dat / Huffman.dat /
FileTable.dat live from the upstream repo on first use and caches in memory,
so a database revision upstream is informational only. This script only
*measures* code drift and *records the baseline* the port mirrors. The model
reads its JSON output plus the real upstream diff and does the porting.

Stdlib only, deterministic: the same upstream commit and state always give the
same output, so a sync is a reviewable diff, never a surprise.
"""

import argparse
import json
import os
import re
import subprocess
import sys

# --------------------------------------------------------------------------
# path resolution
# --------------------------------------------------------------------------

HERE = os.path.dirname(os.path.abspath(__file__))
# script dir = <app>/Skills/sync-mea-engine/scripts
DEFAULT_APP_ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
DEFAULT_UPSTREAM = os.path.normpath(
    os.environ.get("MEA_UPSTREAM_PATH", os.path.join(DEFAULT_APP_ROOT, "..", "MEAnalyzer"))
)
DEFAULT_PKG = "Packages/MEFirmware"

CODE_FILE = "MEA.py"
# Data files are classified, never copied. The module fetches them live.
DATA_FILES = ("MEA.dat", "Huffman.dat", "FileTable.dat")


def log(msg):
    print(msg)


def die(msg, code=2):
    print("error: " + msg, file=sys.stderr)
    sys.exit(code)


def git(repo, *args):
    """Run git in `repo`; return (returncode, stdout). Never raises."""
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    return proc.returncode, proc.stdout


# --------------------------------------------------------------------------
# state file
# --------------------------------------------------------------------------


def state_path(app_root, pkg):
    return os.path.join(app_root, pkg, "Sync", "mea-sync-state.json")


def load_state(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, sort_keys=True)
        f.write("\n")


# --------------------------------------------------------------------------
# MEA.py symbol/block parsing
# --------------------------------------------------------------------------

TOP_LEVEL = re.compile(r"^(class|def)\s+([A-Za-z_][A-Za-z0-9_]*)")


def parse_blocks(text):
    """Split source into top-level blocks keyed by `kind:name`.

    A block runs from a column-0 `class X:` / `def x():` line to the next
    column-0 `class`/`def` line. Method names are collected per class so a
    method-only edit still shows up in the diff summary.
    """
    blocks = {}
    methods = {}
    current = None
    buf = []
    lines = text.splitlines(keepends=True)

    def flush():
        if current is not None:
            blocks[current] = "".join(buf)

    for line in lines:
        m = TOP_LEVEL.match(line)
        if m and not line.startswith(" "):
            flush()
            current = "%s:%s" % (m.group(1), m.group(2))
            buf = [line]
            continue
        mm = re.match(r"^    def\s+([A-Za-z_][A-Za-z0-9_]*)", line)
        if mm and current and current.startswith("class:"):
            methods.setdefault(current, []).append(mm.group(1))
        if current is not None:
            buf.append(line)
    flush()
    return blocks, methods


def symbol_sets(repo, baseline, head):
    """(added, changed, removed) symbol lists for MEA.py across the range."""
    code, old = git(repo, "show", "%s:%s" % (baseline, CODE_FILE))
    old_ok = code == 0
    _, new = git(repo, "show", "%s:%s" % (head, CODE_FILE))
    if not old_ok:
        return None  # MEA.py did not exist at baseline -> treat all as added
    old_blocks, old_m = parse_blocks(old)
    new_blocks, new_m = parse_blocks(new)

    added, changed, removed = [], [], []
    for sym, body in new_blocks.items():
        if sym not in old_blocks:
            added.append(sym)
        elif old_blocks[sym] != body:
            note = ""
            if sym.startswith("class:"):
                old_extra = set(old_m.get(sym, []))
                new_extra = set(new_m.get(sym, []))
                if old_extra != new_extra:
                    note = " methods± " + ",".join(sorted(old_extra ^ new_extra))
            changed.append(sym + note)
    for sym in old_blocks:
        if sym not in new_blocks:
            removed.append(sym)
    return sorted(added), sorted(changed), sorted(removed)


# --------------------------------------------------------------------------
# diff helpers
# --------------------------------------------------------------------------


def changed_files(repo, baseline, head):
    """name-status list for baseline..head, or [] on failure."""
    code, out = git(repo, "diff", "--name-status", "%s..%s" % (baseline, head))
    if code != 0:
        return []
    return [line.split("\t", 1) for line in out.splitlines() if "\t" in line]


def numstat(repo, baseline, head, path):
    """(added, deleted) line counts for one path over the range."""
    code, out = git(repo, "diff", "--numstat", "%s..%s" % (baseline, head), "--", path)
    if code != 0 or not out.strip():
        return (0, 0)
    try:
        a, d, _ = out.splitlines()[0].split("\t")
        return (int(a), int(d))
    except ValueError:
        return (0, 0)


def head_info(repo):
    code, head = git(repo, "rev-parse", "HEAD")
    if code != 0:
        die("not a git clone: %s (set MEA_UPSTREAM_PATH or --source)" % repo)
    head = head.strip()
    return head, head_tag(repo, head)


def head_tag(repo, sha):
    _, tag = git(repo, "describe", "--tags", "--exact-match", sha)
    return tag.strip() if tag else None


# --------------------------------------------------------------------------
# subcommands
# --------------------------------------------------------------------------


def cmd_check(args, state_path_abs):
    repo = args.source
    head, tag = head_info(repo)
    state = load_state(state_path_abs)
    baseline = (state.get("upstream") or {}).get("baselineSHA")
    if args.baseline_sha:
        baseline = args.baseline_sha
    if not baseline:
        baseline = head
        log("no baseline in state; using current HEAD as baseline")

    if not args.no_fetch:
        rc, _ = git(repo, "fetch", "origin")
        if rc != 0:
            log("warning: git fetch failed (offline?); continuing with local refs")
        head, tag = head_info(repo)

    report = {
        "skill": "sync-mea-engine",
        "upstream": {"path": repo, "baselineSHA": baseline, "headSHA": head, "headTag": tag},
        "changed_files": [],
        "noise": [],
    }
    code_files, noise = [], []
    for status, path in changed_files(repo, baseline, head):
        path = path.strip('"')
        if path in DATA_FILES:
            continue  # data is live-fetched by the module; classified below
        if path == CODE_FILE:
            code_files.append(status)
        else:
            noise.append(path)
        report["changed_files"].append("%s\t%s" % (status, path))

    # Database revisions are informational: how far the module's live fetch will jump.
    db = {}
    for path in DATA_FILES:
        added, deleted = numstat(repo, baseline, head, path)
        if added or deleted:
            db[path] = {"added_lines": added, "deleted_lines": deleted}
    if db:
        report["db"] = db

    if code_files:
        sets = symbol_sets(repo, baseline, head)
        if sets is None:
            report["code_added"] = ["MEA.py (no baseline file; whole port pending)"]
        else:
            report["code_added"] = sets[0]
            report["code_changed"] = sets[1]
            report["code_removed"] = sets[2]

    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2, sort_keys=True)
        log("wrote %s" % args.json)

    log("baseline: %s" % baseline)
    log("head:     %s%s" % (head[:12], ("  (%s)" % tag) if tag else ""))
    log("db moved (info only): %s" % (json.dumps(db) if db else "none"))
    log("MEA.py added:   %d" % len(report.get("code_added", [])))
    log("MEA.py changed: %d" % len(report.get("code_changed", [])))
    log("MEA.py removed: %d" % len(report.get("code_removed", [])))
    log("noise (docs etc): %d" % len(noise))
    return 0 if not (report.get("code_added") or report.get("code_changed") or report.get("code_removed")) else 1


def cmd_pin(args, state_path_abs, verb):
    repo = args.source
    if args.baseline_sha:
        head = args.baseline_sha
        rc, _ = git(repo, "rev-parse", "--verify", "%s^{commit}" % head)
        if rc != 0:
            die("not a commit in upstream: %s" % head)
    else:
        head, _ = head_info(repo)
    state = load_state(state_path_abs)
    state.setdefault("upstream", {})
    state["upstream"].update({"baselineSHA": head, "baselineTag": head_tag(repo, head)})
    save_state(state_path_abs, state)
    log("%s: baseline pinned to %s %s" % (verb, head[:12], state["upstream"]["baselineTag"] or ""))
    log("state: %s" % state_path_abs)


def cmd_bootstrap(args):
    # Bootstrap is primarily model work (see SKILL.md). The script only lays
    # the deterministic scaffolding the model then fills. No Resources dir: the
    # module fetches its databases live, so none are baked in.
    pkg_dir = os.path.normpath(os.path.join(args.app_root, args.pkg))
    # Refuse to overwrite a real package; a bare scaffold (empty dirs) is fine to
    # re-run and just gets the baseline re-pinned.
    if os.path.isfile(os.path.join(pkg_dir, "Package.swift")):
        die("package already exists (Package.swift present): %s" % pkg_dir)
    name = os.path.basename(args.pkg)
    os.makedirs(os.path.join(pkg_dir, "Sources", name, "Models"), exist_ok=True)
    os.makedirs(os.path.join(pkg_dir, "Sources", name, "Data"), exist_ok=True)
    os.makedirs(os.path.join(pkg_dir, "Tests", name + "Tests"), exist_ok=True)
    os.makedirs(os.path.join(pkg_dir, "Sync"), exist_ok=True)
    log("scaffolded %s (empty) — model fills Package.swift, sources, model and async data provider" % pkg_dir)
    cmd_pin(args, state_path(args.app_root, args.pkg), "bootstrap")


# --------------------------------------------------------------------------
# argparse
# --------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--app-root", default=DEFAULT_APP_ROOT,
                    help="DumpCompare root (default: resolved next to this script)")
    ap.add_argument("--source", default=DEFAULT_UPSTREAM,
                    help="upstream MEAnalyzer git clone (default: $MEA_UPSTREAM_PATH or sibling ../MEAnalyzer)")
    ap.add_argument("--pkg", default=DEFAULT_PKG, help="engine package under app root (default: %(default)s)")
    ap.add_argument("--no-fetch", action="store_true", help="do not git fetch the upstream clone")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_check = sub.add_parser("check", help="diff baseline..HEAD and report drift (read-only)")
    p_check.add_argument("--json", help="write machine report to this path")
    p_check.add_argument("--baseline-sha", help="override baseline commit for this run")
    p_check.set_defaults(fn=lambda a, s: cmd_check(a, s))

    # sync and baseline both pin the baseline commit the Swift port mirrors.
    for sub_name, verb in (("sync", "sync"), ("baseline", "baseline")):
        p = sub.add_parser(sub_name, help="pin the baseline commit (code port is model work)")
        p.add_argument("--sha", dest="baseline_sha", help="upstream commit to pin (default: HEAD)")
        p.set_defaults(fn=lambda a, s, v=verb: cmd_pin(a, s, v))

    p_boot = sub.add_parser("bootstrap", help="scaffold an empty Packages/MEFirmware and pin baseline")
    p_boot.set_defaults(fn=None, baseline_sha=None)

    args = ap.parse_args()

    if not os.path.isdir(os.path.join(args.source, ".git")):
        die("upstream clone not found at %s (set MEA_UPSTREAM_PATH or --source)" % args.source)

    if args.cmd == "bootstrap":
        return cmd_bootstrap(args)
    return args.fn(args, state_path(args.app_root, args.pkg))


if __name__ == "__main__":
    sys.exit(main())
