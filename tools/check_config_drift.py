#!/usr/bin/env python3
"""Compare prepareconfig output against `make olddefconfig`.

For every line the kernel drops or rewrites, also try to explain why
by locating the symbol in the Kconfig tree and reporting its
type/dependencies/selects/defaults.

Usage: check_config_drift.py <arch> <flavor>
  arch:   arm64 | x86_64
  flavor: debug | default | hardened   (hardened => x86_64 only)
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PREPARE = Path("facebook/scripts/prepareconfig")
CONFIGS = Path("facebook/config/")
BUILD_MACHINERY = Path(f"/home/{os.environ.get('USER', '')}/local/build_machinery")

SET_RE   = re.compile(r"^(CONFIG_[A-Z0-9_]+)=(.*)$")
UNSET_RE = re.compile(r"^# (CONFIG_[A-Z0-9_]+) is not set$")

CFG_DEF_RE = re.compile(r"^\s*(?:menu)?config\s+([A-Z0-9_]+)\s*$")
BLOCK_END_RE = re.compile(
    r"^\s*(?:menu|endmenu|endif|if|choice|endchoice|source|comment|"
    r"(?:menu)?config)\b"
)
INTERESTING_RE = re.compile(
    r"^\s*(bool|tristate|string|int|hex|def_bool|def_tristate|"
    r"depends on|select|imply|default|prompt|range)\b"
)


def parse_config(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        m = SET_RE.match(raw) or UNSET_RE.match(raw)
        if m:
            out[m.group(1)] = raw
    return out


def sym_of(line: str) -> str:
    m = SET_RE.match(line) or UNSET_RE.match(line)
    return m.group(1) if m else ""


ARCH_DIR = {"arm64": "arm64", "x86_64": "x86"}


def build_kconfig_index(
    root: Path, arch: str
) -> dict[str, list[tuple[Path, int, list[str]]]]:
    """{SYMBOL: [(path, lineno, [interesting lines])]}.

    Skips Kconfig files under arch/ subtrees that don't match `arch`,
    so e.g. `arch/x86/Kconfig` won't pollute an arm64 run.
    """
    keep_arch = ARCH_DIR[arch]
    index: dict[str, list[tuple[Path, int, list[str]]]] = {}
    for kfile in root.rglob("Kconfig*"):
        s = str(kfile)
        if "/Documentation/" in s:
            continue
        parts = kfile.parts
        if "arch" in parts:
            i = parts.index("arch")
            if i + 1 < len(parts) and parts[i + 1] != keep_arch:
                continue
        try:
            lines = kfile.read_text(errors="replace").splitlines()
        except OSError:
            continue
        i = 0
        while i < len(lines):
            m = CFG_DEF_RE.match(lines[i])
            if not m:
                i += 1
                continue
            sym = m.group(1)
            start = i
            body: list[str] = []
            j = i + 1
            while j < len(lines):
                if CFG_DEF_RE.match(lines[j]) or (
                    BLOCK_END_RE.match(lines[j])
                    and not lines[j].lstrip().startswith(("depends", "select",
                        "imply", "default", "prompt", "range", "bool",
                        "tristate", "string", "int", "hex", "def_bool",
                        "def_tristate"))
                ):
                    break
                if INTERESTING_RE.match(lines[j]):
                    body.append(lines[j].strip())
                j += 1
            index.setdefault(f"CONFIG_{sym}", []).append((kfile, start + 1, body))
            i = j
    return index


KCONFIG_KEYWORDS = {
    "IF", "ON", "DEPENDS", "SELECT", "IMPLY", "DEFAULT", "BOOL", "TRISTATE",
    "STRING", "INT", "HEX", "RANGE", "PROMPT", "DEF_BOOL", "DEF_TRISTATE",
    "Y", "N", "M",
}
SYM_TOKEN = re.compile(r"\b([A-Z_][A-Z0-9_]+)\b")


def purge_from_build_machinery(sym: str, upstream_commit: str | None) -> None:
    """Delete every line that mentions `sym` from build_machinery's
    facebook/config fragments and create a git commit there.
    """
    cfg_dir = BUILD_MACHINERY / "facebook/config"
    if not cfg_dir.is_dir():
        print(f"    purge: {cfg_dir} not found, skipping.")
        return

    pattern = re.compile(
        rf"^(?:{re.escape(sym)}=|# {re.escape(sym)} is not set)"
    )
    changed: list[Path] = []
    for f in sorted(list(cfg_dir.glob("*.config")) + list(cfg_dir.glob("*.bootconfig"))):
        lines = f.read_text().splitlines(keepends=True)
        kept = [l for l in lines if not pattern.match(l)]
        if len(kept) != len(lines):
            f.write_text("".join(kept))
            changed.append(f.relative_to(BUILD_MACHINERY))
            print(f"    purge: stripped {len(lines)-len(kept)} line(s) from {f}")

    if not changed:
        print("    purge: no fragments mentioned the symbol; nothing to commit.")
        return

    if not upstream_commit:
        print("    purge: aborting — upstream removal commit could not be pinpointed.")
        print("    purge: leaving fragment edits unstaged for inspection.")
        return
    sha, _, subject = upstream_commit.partition(" ")
    upstream_blurb = f'Removed in upstream kernel by commit {sha} ("{subject}").'
    msg = (
        f"[build_machinery] facebook/config: drop {sym}\n"
        f"\n"
        f"{upstream_blurb}\n"
        f"\n"
        f"Signed-off-by: Breno Leitao <leitao@debian.org>\n"
    )
    add = subprocess.run(
        ["git", "-C", str(BUILD_MACHINERY), "add", *map(str, changed)],
    )
    if add.returncode != 0:
        print("    purge: git add failed.")
        return
    commit = subprocess.run(
        ["git", "-C", str(BUILD_MACHINERY), "commit", "-m", msg],
    )
    if commit.returncode != 0:
        print("    purge: git commit failed.")
        return
    print(f"    purge: committed in {BUILD_MACHINERY}")


UPSTREAM_REF = "linux-next-remote/master"


def find_removal_commit(bare_sym: str) -> str | None:
    """Use `git log -G` on the upstream linux-next branch to find the
    most recent commit whose diff hit a `config <SYM>` line in any
    Kconfig file. Returns 'sha subject' or None."""
    try:
        r = subprocess.run(
            ["git", "log", "-1", UPSTREAM_REF,
             "-G", rf"^\s*config {bare_sym}\b",
             "--pretty=format:%h %s", "--abbrev=12", "--", "*Kconfig*"],
            capture_output=True, text=True, timeout=300,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout.strip() or None


def annotate(line: str, cfg: dict[str, str]) -> str:
    """Append the current .config status of every CONFIG symbol on `line`."""
    seen: list[str] = []
    for tok in SYM_TOKEN.findall(line):
        if tok in KCONFIG_KEYWORDS or tok in seen:
            continue
        seen.append(tok)
    if not seen:
        return line
    notes = []
    for tok in seen:
        key = f"CONFIG_{tok}"
        raw = cfg.get(key)
        if raw is None:
            notes.append(f"{tok}=<absent>")
        elif raw.startswith("# "):
            notes.append(f"{tok}=n")
        else:
            val = raw.split("=", 1)[1]
            notes.append(f"{tok}={val}")
    return f"{line}    [{', '.join(notes)}]"


def explain(sym: str, index, cfg: dict[str, str] | None = None,
            find_removed: bool = False) -> list[str]:
    defs = index.get(sym)
    if not defs:
        out = ["    (no Kconfig definition found — symbol is unknown / removed / renamed)"]
        if find_removed:
            bare = sym[len("CONFIG_"):]
            commit = find_removal_commit(bare)
            if commit:
                out.append(f"        last touched by: {commit}")
            else:
                out.append("        (couldn't pinpoint the removal commit via git log -G)")
        return out
    out = []
    for path, lineno, body in defs:
        out.append(f"    def: {path}:{lineno}")
        for b in body[:12]:
            out.append(f"        {annotate(b, cfg) if cfg else b}")
        if len(body) > 12:
            out.append(f"        ... (+{len(body)-12} more)")
    return out


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("arch", choices=["arm64", "x86_64"])
    p.add_argument(
        "flavor",
        nargs="?",
        choices=["debug", "default", "hardened"],
        help="Required unless --detail is given.",
    )
    p.add_argument(
        "--show",
        choices=["all", "dropped", "changed"],
        default="all",
        help="Which drift entries to print (default: all).",
    )
    p.add_argument(
        "--detail",
        metavar="CONFIG_SYM",
        help="Print Kconfig details for this single symbol and exit. "
             "Skips prepareconfig/olddefconfig.",
    )
    p.add_argument(
        "--explain",
        action="store_true",
        help="In drift mode, print Kconfig details for each reported entry "
             "(definition site, deps annotated with current .config values).",
    )
    p.add_argument(
        "--purge-removed",
        action="store_true",
        help="With --detail: if the symbol is removed upstream, delete every "
             "occurrence from build_machinery's facebook/config fragments and "
             "create a git commit there citing the upstream removal commit.",
    )
    args = p.parse_args()

    if args.detail:
        sym = args.detail if args.detail.startswith("CONFIG_") else f"CONFIG_{args.detail}"
        bare = sym[len("CONFIG_"):]
        index = build_kconfig_index(Path("."), args.arch)
        cfg_path = Path(".config")
        cfg = parse_config(cfg_path) if cfg_path.exists() else {}
        print(sym)
        if sym not in index:
            print("    *** REMOVED: no Kconfig in this tree defines this symbol.")
            print(f"        searching git history for the commit that removed `config {bare}`...",
                  flush=True)
            commit = find_removal_commit(bare)
            if commit:
                print(f"        last touched by: {commit}")
            else:
                print("        (couldn't pinpoint the removal commit via git log -G)")

            if args.purge_removed:
                purge_from_build_machinery(sym, commit)
                return 0
        elif args.purge_removed:
            print("    --purge-removed ignored: symbol still exists in the kernel tree.")
        if not cfg:
            print("    (no .config found in cwd — dependency annotations skipped)")

        # Where in the fb config fragments is this symbol mentioned?
        # Restrict to fragments actually used by this arch/flavor combo,
        # mirroring prepareconfig's selection.
        wanted = ["common.config", f"arch-{args.arch}.config"]
        if args.flavor and args.flavor != "default":
            wanted.append(f"flavor-{args.flavor}-{args.arch}.config")
        frag_files = [CONFIGS / w for w in wanted if (CONFIGS / w).exists()]
        frag_hits: list[tuple[Path, int, str]] = []
        frag_re = re.compile(
            rf"^(?:{re.escape(sym)}=|# {re.escape(sym)} is not set)"
        )
        for f in frag_files:
            for n, raw in enumerate(f.read_text(errors="replace").splitlines(), 1):
                if frag_re.match(raw):
                    frag_hits.append((f, n, raw))
        final = cfg.get(sym)
        # Suppress when ABSENT and fragments only ever turned it off (=n or "is not set").
        only_off = bool(frag_hits) and all(
            raw.startswith("# ") or raw.startswith(f"{sym}=n")
            for _, _, raw in frag_hits
        )
        if final is None and only_off:
            print("    ABSENT in final .config; fragments only set it off — nothing to report.")
            return 0

        if frag_hits:
            print("    fragments that set this symbol:")
            for f, n, raw in frag_hits:
                print(f"        {f}:{n}: {raw}")
        else:
            print("    (no facebook/config/ fragment mentions this symbol)")

        if final is None:
            final_state = "ABSENT  (dropped or never reachable)"
        elif final.startswith("# "):
            final_state = "n"
        else:
            final_state = final.split("=", 1)[1]
        print(f"    final .config state: {final_state}")

        # If a fragment requested it on but final isn't on, look for unmet deps.
        wanted_on = any(
            raw.startswith(f"{sym}=") and not raw.startswith(f"{sym}=n")
            for _, _, raw in frag_hits
        )
        on_now = final is not None and not final.startswith("# ") \
                 and not final.endswith("=n")
        if wanted_on and not on_now and cfg:
            print("    requested ON by fragment, but disabled by Kconfig.")
            print("    unmet pieces on `depends on`/`if` clauses:")
            for _, _, body in index.get(sym, []):
                for line in body:
                    if not re.match(r"^\s*(depends on|if|.*\bif\b)", line):
                        continue
                    bad = []
                    for tok in SYM_TOKEN.findall(line):
                        if tok in KCONFIG_KEYWORDS or tok == bare:
                            continue
                        v = cfg.get(f"CONFIG_{tok}")
                        if v is None or v.startswith("# "):
                            bad.append(tok)
                    if bad:
                        print(f"        {line}    UNMET: {', '.join(bad)}")

        for l in explain(sym, index, cfg):
            print(l)
        return 0

    if not args.flavor:
        p.error("flavor is required unless --detail is given")
    if args.flavor == "hardened" and args.arch != "x86_64":
        p.error("hardened flavor is only available for x86_64")

    tag = f"{args.arch}-{args.flavor}"
    outdir = Path(tempfile.mkdtemp(prefix=f"configdrift.{tag}."))
    orig  = outdir / f"{tag}.orig"
    final = outdir / f"{tag}.final"
    mlog  = outdir / "make.log"
    print(f"Working dir: {outdir}")
    print(f"=== {tag} ===")

    with orig.open("w") as fh, (outdir / "prepare.log").open("w") as log:
        r = subprocess.run(
            [str(PREPARE), "-a", args.arch, "-f", args.flavor, "-p", str(CONFIGS)],
            stdout=fh, stderr=log,
        )
    if r.returncode != 0:
        print(f"prepareconfig failed (see {outdir}/prepare.log)", file=sys.stderr)
        return 1

    shutil.copy(orig, ".config")
    with mlog.open("w") as log:
        r = subprocess.run(
            ["make", f"ARCH={args.arch}", "LLVM=1", "olddefconfig"],
            stdout=log, stderr=subprocess.STDOUT,
        )
    if r.returncode != 0:
        print(f"make olddefconfig failed (see {mlog})", file=sys.stderr)
        return 1
    shutil.copy(".config", final)

    orig_map  = parse_config(orig)
    final_map = parse_config(final)

    def value(line: str) -> str:
        # Canonicalize: "# CONFIG_X is not set" and "CONFIG_X=n" both mean off.
        if line.startswith("# "):
            return "n"
        v = line.split("=", 1)[1]
        return "n" if v == "n" else v

    dropped, changed = [], []
    for sym, line in orig_map.items():
        new = final_map.get(sym)
        if new is None:
            dropped.append(line)
        elif value(new) != value(line):
            changed.append((line, new))

    index = build_kconfig_index(Path("."), args.arch) if args.explain else None
    cfg = final_map if args.explain else None

    if args.show in ("all", "dropped"):
        for line in dropped:
            # Skip noisy "# CONFIG_X is not set" entries that just disappeared:
            # the fragment only asked for off, and the final .config also has
            # it off (absent). Nothing actionable to report.
            if line.startswith("# "):
                continue
            print()
            print(f"DROPPED:  {line}")
            if args.explain:
                for l in explain(sym_of(line), index, cfg, find_removed=True):
                    print(l)
    if args.show in ("all", "changed"):
        for old, new in changed:
            print(f"CHANGED:  {old}")
            print(f"          -> {new}")
            if args.explain:
                for l in explain(sym_of(old), index, cfg, find_removed=True):
                    print(l)

    print(f"\ndropped: {len(dropped)}   changed: {len(changed)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
