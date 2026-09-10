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
# MEA.py segmentation
# --------------------------------------------------------------------------
#
# MEA.py is one ~14k-line file, and only its first ~10.5k lines live inside a
# `class`/`def`. The rest is module-level: lookup tables, the anchor regexes,
# and the per-file analysis loop that upstream's whole default output is
# printed from. Keyed by top-level symbol alone, that tail collapses into
# whichever `def` happens to come last — so a change to the code this port
# leans on hardest gets reported under an unrelated name.
#
# So the tail is segmented too, by the structure upstream already wrote into
# it rather than by a phase list kept here (which would rot at the next
# release):
#
# - a column-0 `class`/`def` opens a block, as before, keyed `class:X`/`def:x`
# - a column-0 comment opens a module-level segment, keyed `module:<comment>`
#   (verified safe: no column-0 comment in MEA.py is followed by indented code)
# - inside a column-0 compound statement — the analysis loop, the CLI ifs —
#   every indent-4 comment or compound line opens a segment, keyed
#   `main:<comment or condition>`. Upstream comments each branch of its
#   variant and firmware-type chains, so those names come out readable.
#
# `elif`/`else` open segments of their own rather than continuing the chain
# they belong to, because upstream's variant chain is one if/elif run ~920
# lines long and every branch of it is ported separately. Three rules keep the
# names readable while it does that: a compound opening directly under its own
# comment continues that comment's segment (the comment is the better name), a
# one-line `elif` row opens nothing (it is a table row, not a phase), and a
# bare `else`/`except` borrows the label of the chain it continues.

TOP_LEVEL = re.compile(r"^(class|def)\s+([A-Za-z_][A-Za-z0-9_]*)")
COMPOUND = re.compile(r"^(if|elif|else|for|while|with|try|except|finally|match|case)\b")
# The body indent of a column-0 compound statement.
INDENT1 = "    "
# Joins a borrowed label to the branch keyword that borrowed it.
SUB = " \u203a "
# How much of an anchor's text becomes the segment name.
NAME_CAP = 78
# Branch keywords that say nothing on their own.
BORROWERS = ("else", "except", "finally")


def _opens_block(stripped):
    """A compound statement that owns following lines, rather than carrying its
    whole body on one line. Upstream writes long one-line `elif` chains
    (`elif fw_type == 'Stock' : type_db = 'RGN'`); those are rows of a table,
    not segments, so they stay with the segment around them."""
    if not COMPOUND.match(stripped):
        return False
    code = stripped.partition("#")[0].rstrip()
    return code.endswith(":")


def _anchor_name(line):
    """A segment name from the line that opens it: its trailing comment when
    it has one (upstream labels its branches), else the statement itself."""
    text = line.strip()
    if text.startswith("#"):
        text = text.lstrip("#").strip()
    else:
        # `elif variant == 'CSME' : # Converged Security Management Engine`
        head, _, comment = text.partition("#")
        text = comment.strip() or head.strip().rstrip(":").strip()
    text = re.sub(r"\s+", " ", text)
    if len(text) <= NAME_CAP:
        return text
    # Elide the middle, not the tail: upstream edits its comments at the end
    # (`FTPR/OROM.man` → `FTPR/RBEP/OROM.man`), and a tail-truncated name
    # would make the before/after pair look identical in the report.
    keep = NAME_CAP - 1
    head_len = keep * 2 // 3
    return text[:head_len] + "…" + text[-(keep - head_len):]


def segment_source(text):
    """Split source into segments covering every line.

    Returns (segments, methods) where `segments` maps `kind:name` to
    {"body", "start", "end"} (1-based inclusive line numbers) and `methods`
    maps a class key to its method names, so a method-only edit still shows in
    the summary.
    """
    segments = {}
    methods = {}
    lines = text.splitlines(keepends=True)

    key = None
    buf = []
    start = 1
    # The column-0 compound statement whose body we are inside, if any. None
    # while inside a class/def or at plain module level.
    in_main = False
    # Whether the open segment was named by a comment, and whether anything
    # but comments and blanks has landed in it yet. Upstream writes
    # `# Firmware Type detection` and then `if ifwi_exist :` on the next line;
    # the comment is the better name for that one segment, so a compound that
    # opens directly under its own comment continues it instead of splitting.
    named_by_comment = False
    has_code = False

    def flush(end):
        if key is None:
            return
        segments[key] = {"body": "".join(buf), "start": start, "end": end}

    def unique(candidate):
        if candidate not in segments:
            return candidate
        n = 2
        while "%s#%d" % (candidate, n) in segments:
            n += 1
        return "%s#%d" % (candidate, n)

    for number, line in enumerate(lines, start=1):
        stripped = line.strip()
        opens = None

        top = TOP_LEVEL.match(line)
        if top:
            opens = "%s:%s" % (top.group(1), top.group(2))
            in_main = False
        elif line[:1] not in (" ", "\t", "\n", "") and stripped:
            # Any other column-0 line. A comment names a module-level segment;
            # a compound statement opens a body whose indent-1 lines are
            # segments of their own; anything else continues the current one.
            if stripped.startswith("#"):
                opens = "module:" + _anchor_name(line)
                in_main = False
            elif _opens_block(stripped):
                in_main = True
                opens = "main:" + _anchor_name(line)
            else:
                in_main = False
        elif in_main and line.startswith(INDENT1) and line[4:5] not in (" ", "\t"):
            if stripped.startswith("#") or _opens_block(stripped):
                opens = "main:" + _anchor_name(line)

        # A bare `else :` / `except …` says nothing on its own, so it borrows
        # the label of the chain it continues.
        if opens is not None and key and not top \
                and opens.split(":", 1)[1] in BORROWERS:
            parent = key.split(":", 1)[1].split(SUB, 1)[0]
            opens = "main:%s%s%s" % (parent[:NAME_CAP - 10], SUB,
                                     opens.split(":", 1)[1])

        if opens is not None and named_by_comment and not has_code \
                and not top and not stripped.startswith("#"):
            # A compound opening under its own comment: same segment, keep the
            # comment's name.
            opens = None
            has_code = True

        if opens is not None:
            flush(number - 1)
            key = unique(opens)
            named_by_comment = stripped.startswith("#")
            has_code = not named_by_comment
            buf = [line]
            start = number
            continue

        if stripped and not stripped.startswith("#"):
            has_code = True

        method = re.match(r"^    def\s+([A-Za-z_][A-Za-z0-9_]*)", line)
        if method and key and key.startswith("class:"):
            methods.setdefault(key, []).append(method.group(1))
        if key is not None:
            buf.append(line)

    flush(len(lines))
    return segments, methods


def symbol_sets(repo, baseline, head):
    """(added, changed, removed) segment lists for MEA.py across the range."""
    code, old = git(repo, "show", "%s:%s" % (baseline, CODE_FILE))
    old_ok = code == 0
    _, new = git(repo, "show", "%s:%s" % (head, CODE_FILE))
    if not old_ok:
        return None  # MEA.py did not exist at baseline -> treat all as added
    old_segments, old_m = segment_source(old)
    new_segments, new_m = segment_source(new)

    added, changed, removed = [], [], []
    for sym, seg in new_segments.items():
        if sym not in old_segments:
            added.append(sym)
        elif old_segments[sym]["body"] != seg["body"]:
            note = ""
            if sym.startswith("class:"):
                old_extra = set(old_m.get(sym, []))
                new_extra = set(new_m.get(sym, []))
                if old_extra != new_extra:
                    note = " methods± " + ",".join(sorted(old_extra ^ new_extra))
            changed.append(sym + note)
    for sym in old_segments:
        if sym not in new_segments:
            removed.append(sym)
    return sorted(added), sorted(changed), sorted(removed)


HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def code_locations(repo, baseline, head):
    """Where the MEA.py changes land, as segments of the HEAD file.

    Every hunk of `baseline..head` is attributed to the segment holding its
    new-side line, so the report can point at a line range instead of a name.
    A pure deletion (new-side count 0) sits between two lines; it is
    attributed to the one it follows, which is the segment it was cut from.
    """
    code, new = git(repo, "show", "%s:%s" % (head, CODE_FILE))
    if code != 0:
        return []
    segments, _ = segment_source(new)
    order = sorted(segments.items(), key=lambda kv: kv[1]["start"])

    code, diff = git(repo, "diff", "--unified=0", "%s..%s" % (baseline, head),
                     "--", CODE_FILE)
    if code != 0:
        return []

    tally = {}
    for line in diff.splitlines():
        m = HUNK.match(line)
        if not m:
            continue
        new_start = int(m.group(3))
        new_count = 1 if m.group(4) is None else int(m.group(4))
        old_count = 1 if m.group(2) is None else int(m.group(2))
        anchor = max(1, new_start)
        owner = None
        for sym, seg in order:
            if seg["start"] <= anchor <= seg["end"]:
                owner = sym
                break
        if owner is None:
            owner = "(before the first segment)"
        slot = tally.setdefault(owner, {"added": 0, "deleted": 0})
        slot["added"] += new_count
        slot["deleted"] += old_count if new_count == 0 else max(0, old_count - new_count)

    located = []
    for sym, counts in tally.items():
        seg = segments.get(sym)
        located.append({
            "segment": sym,
            "lines": "%d-%d" % (seg["start"], seg["end"]) if seg else "?",
            "startLine": seg["start"] if seg else 0,
            "added": counts["added"],
            "deleted": counts["deleted"],
        })
    located.sort(key=lambda item: item["startLine"])
    return located


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

    located = []
    if code_files:
        sets = symbol_sets(repo, baseline, head)
        if sets is None:
            report["code_added"] = ["MEA.py (no baseline file; whole port pending)"]
        else:
            report["code_added"] = sets[0]
            report["code_changed"] = sets[1]
            report["code_removed"] = sets[2]
        # Where the hunks actually land, so the port starts from a line range
        # and not from a name. Still read the real diff before writing Swift.
        located = code_locations(repo, baseline, head)
        if located:
            report["code_locations"] = located

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
    if located:
        log("")
        log("MEA.py hunks by segment (upstream lines at head):")
        for item in located:
            log("  %-11s +%-4d -%-4d  %s" % (item["lines"], item["added"],
                                             item["deleted"], item["segment"]))
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
    p_check.add_argument("--no-fetch", dest="no_fetch_here", action="store_true",
                         help="same as the global flag, accepted after the subcommand too")
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

    args.no_fetch = args.no_fetch or getattr(args, "no_fetch_here", False)

    if args.cmd == "bootstrap":
        return cmd_bootstrap(args)
    return args.fn(args, state_path(args.app_root, args.pkg))


if __name__ == "__main__":
    sys.exit(main())
