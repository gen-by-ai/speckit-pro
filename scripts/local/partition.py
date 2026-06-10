#!/usr/bin/env python3
"""partition.py — dependency-cluster partition of a repo for parallel analysis.

Builds a coarse import/require graph (regex-level, no AST), groups
weakly-connected components, and packs them into N size-balanced portions.
Falls back to size-balanced buckets for the `size-bucket` strategy or for files
with no resolvable edges. Oversized portions are pre-split. Output is
DETERMINISTIC: the same tree + args yields byte-identical portions.json
(stable sorts by path), which is what makes scan reproducibility (SC-006)
checkable.

Stdlib only. CLI contract documented in the pro source repo (feature 001 workspace,
cli-schema.md); output validates against templates/schemas/partial-result.schema.json
and data-model.md (Portion). Part of the SpecKit Pro fan-out engine.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

# Files we bother analyzing, by extension. Everything else is ignored.
CODE_EXTS = {
    ".py", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".go", ".rs",
    ".rb", ".java", ".kt", ".c", ".h", ".cc", ".cpp", ".hpp", ".sh",
    ".bash", ".ps1", ".md", ".yml", ".yaml",
}

# Per-extension import extractors → list of regexes capturing the imported name.
IMPORT_PATTERNS = {
    ".py": [re.compile(r"^\s*import\s+([A-Za-z0-9_.]+)"),
            re.compile(r"^\s*from\s+([A-Za-z0-9_.]+)\s+import")],
    ".js": [re.compile(r"""require\(['"]([^'"]+)['"]\)"""),
            re.compile(r"""from\s+['"]([^'"]+)['"]""")],
    ".go": [re.compile(r'^\s*"([^"]+)"\s*$')],
    ".sh": [re.compile(r"^\s*(?:source|\.)\s+([^\s;]+)")],
    ".md": [re.compile(r"\]\(([^)]+\.(?:sh|py|md|ya?ml))\)")],
}
# share JS patterns across the JS/TS family
for _e in (".jsx", ".ts", ".tsx", ".mjs", ".cjs"):
    IMPORT_PATTERNS[_e] = IMPORT_PATTERNS[".js"]
IMPORT_PATTERNS[".bash"] = IMPORT_PATTERNS[".sh"]


def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)


def list_files(root):
    """Tracked + untracked-but-not-ignored files, filtered to code extensions.

    Falls back to os.walk when the dir is not a git repo.
    """
    res = run(["git", "ls-files", "--cached", "--others", "--exclude-standard"], root)
    if res.returncode == 0 and res.stdout.strip():
        paths = res.stdout.splitlines()
    else:
        paths = []
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules", "__pycache__")]
            for fn in filenames:
                rel = os.path.relpath(os.path.join(dirpath, fn), root)
                paths.append(rel)
    out = []
    for p in paths:
        if os.path.splitext(p)[1].lower() in CODE_EXTS:
            ap = os.path.join(root, p)
            try:
                if os.path.isfile(ap) and not os.path.islink(ap):
                    out.append(p)
            except OSError:
                pass
    return sorted(set(out))  # deterministic


def est_tokens(root, rel):
    try:
        return max(1, os.path.getsize(os.path.join(root, rel)) // 4)
    except OSError:
        return 1


def build_index(files):
    """Maps for resolving an import target to a repo file."""
    by_basename = defaultdict(list)       # 'auth' -> ['src/auth.py', ...]
    by_relstem = {}                       # 'src/auth' -> 'src/auth.py'
    for f in files:
        stem, _ = os.path.splitext(f)
        by_relstem[stem] = f
        by_relstem[f] = f
        by_basename[os.path.basename(stem)].append(f)
    return by_basename, by_relstem


def extract_imports(root, rel):
    ext = os.path.splitext(rel)[1].lower()
    pats = IMPORT_PATTERNS.get(ext)
    if not pats:
        return []
    hits = []
    try:
        with open(os.path.join(root, rel), "r", encoding="utf-8", errors="ignore") as fh:
            for i, line in enumerate(fh):
                if i > 800:  # cap: imports live near the top
                    break
                for pat in pats:
                    m = pat.search(line)
                    if m:
                        hits.append(m.group(1))
    except OSError:
        pass
    return hits


def resolve(target, src_rel, by_basename, by_relstem):
    """Best-effort: map an import string to a repo file path, or None."""
    # relative path (./x, ../x, source ./lib.sh)
    cand = target.lstrip("./").replace("\\", "/")
    base_dir = os.path.dirname(src_rel)
    for guess in (
        os.path.normpath(os.path.join(base_dir, cand)),
        cand,
        cand.replace(".", "/"),  # python dotted → path
    ):
        if guess in by_relstem:
            return by_relstem[guess]
    # basename match (last path/module segment)
    leaf = re.split(r"[/.]", cand.rstrip("/"))[-1]
    matches = by_basename.get(leaf)
    if matches and len(matches) == 1:
        return matches[0]
    return None


class UnionFind:
    def __init__(self, items):
        self.parent = {x: x for x in items}

    def find(self, x):
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            # deterministic: smaller path becomes root
            lo, hi = sorted((ra, rb))
            self.parent[hi] = lo


def cluster_label(files):
    """Dominant top-level directory (or 'root') of a portion's files."""
    tops = defaultdict(int)
    for f in files:
        parts = f.split("/")
        tops[parts[0] if len(parts) > 1 else "(root)"] += 1
    return sorted(tops.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]


def components(files, root):
    uf = UnionFind(files)
    fileset = set(files)
    by_basename, by_relstem = build_index(files)
    for f in files:
        for tgt in extract_imports(root, f):
            r = resolve(tgt, f, by_basename, by_relstem)
            if r and r in fileset and r != f:
                uf.union(f, r)
    groups = defaultdict(list)
    for f in files:
        groups[uf.find(f)].append(f)
    # deterministic ordering: by descending size, then by min path
    comps = []
    for root_key, members in groups.items():
        members = sorted(members)
        size = sum(est_tokens(root, m) for m in members)
        comps.append({"files": members, "size": size, "min": members[0]})
    comps.sort(key=lambda c: (-c["size"], c["min"]))
    return comps


def split_oversized(comp, root, max_tokens, label):
    """Split a too-big component into <=max_tokens leaf chunks (sorted by path)."""
    chunks, cur, cur_size = [], [], 0
    for f in comp["files"]:
        t = est_tokens(root, f)
        if cur and cur_size + t > max_tokens:
            chunks.append(cur)
            cur, cur_size = [], 0
        cur.append(f)
        cur_size += t
    if cur:
        chunks.append(cur)
    return chunks


def pack(comps, workers, root, max_tokens):
    """Greedy balanced bin-packing of components into `workers` portions.

    Oversized components are pre-split into sub-portions first.
    """
    units = []  # each: {files, size, parent_label or None}
    for c in comps:
        if max_tokens and c["size"] > max_tokens and len(c["files"]) > 1:
            label = cluster_label(c["files"])
            for chunk in split_oversized(c, root, max_tokens, label):
                units.append({"files": chunk,
                              "size": sum(est_tokens(root, f) for f in chunk),
                              "parent_label": label})
        else:
            units.append({"files": c["files"], "size": c["size"], "parent_label": None})
    units.sort(key=lambda u: (-u["size"], u["files"][0]))

    n = max(1, workers)
    bins = [{"files": [], "size": 0} for _ in range(n)]
    for u in units:
        # smallest current bin; ties broken by index for determinism
        bi = min(range(n), key=lambda i: (bins[i]["size"], i))
        bins[bi]["files"].extend(u["files"])
        bins[bi]["size"] += u["size"]
    return [b for b in bins if b["files"]]


def main():
    ap = argparse.ArgumentParser(description="Build a dependency-cluster partition for parallel analysis.")
    ap.add_argument("--root", default=".", help="repo root to scan")
    ap.add_argument("--workers", type=int, default=4, help="target number of portions")
    ap.add_argument("--strategy", choices=["dependency-cluster", "size-bucket"], default="dependency-cluster")
    ap.add_argument("--max-tokens", type=int, default=0, help="per-portion token budget (0 = no oversized split)")
    ap.add_argument("--out", default="", help="write portions.json here (default: stdout)")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    files = list_files(root)
    if not files:
        sys.stderr.write("partition.py: no code files found under %s\n" % root)

    if args.strategy == "size-bucket":
        comps = [{"files": [f], "size": est_tokens(root, f), "min": f} for f in files]
        comps.sort(key=lambda c: (-c["size"], c["min"]))
    else:
        comps = components(files, root)

    # small-repo fast path: fewer files than 2x workers → single portion
    if len(files) <= max(2, args.workers):
        bins = [{"files": files, "size": sum(est_tokens(root, f) for f in files)}] if files else []
    else:
        bins = pack(comps, args.workers, root, args.max_tokens)

    width = max(2, len(str(len(bins))))
    portions = []
    for i, b in enumerate(sorted(bins, key=lambda x: x["files"][0]), start=1):
        pid = "p" + str(i).zfill(width)
        portions.append({
            "portion_id": pid,
            "files": b["files"],
            "cluster_label": cluster_label(b["files"]),
            "est_tokens": b["size"],
            "parent_portion_id": None,
        })

    doc = {
        "strategy": args.strategy,
        "workers": args.workers,
        "file_count": len(files),
        "portion_count": len(portions),
        "portions": portions,
    }
    out = json.dumps(doc, indent=2, sort_keys=False) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(out)
        sys.stderr.write("partition.py: wrote %d portions (%d files) → %s\n"
                         % (len(portions), len(files), args.out))
    else:
        sys.stdout.write(out)


if __name__ == "__main__":
    main()
