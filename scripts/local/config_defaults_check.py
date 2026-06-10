#!/usr/bin/env python3
"""config_defaults_check.py — detect default-value drift between config sources.

SpecKit Pro ships defaults in TWO places that must agree (FR-013):

  - extension.yml          → the `defaults:` subtree (layer-4 fallback)
  - pro-config.template.yml → the whole document (what projects copy)

This script parses both with a minimal indentation-based YAML-subset reader
(stdlib only — PyYAML is not a dependency and must not become one), flattens
each into dotted-path → scalar maps, and reports value differences over the
SHARED paths. Paths present in only one source are listed informationally —
the template carries documentation-only keys with no extension.yml
counterpart and vice versa; those are NOT counted as mismatches.

Parser subset (sufficient for these two files): nested mappings with scalar
leaves; quote-aware comment stripping; list items (`- …`) and block scalars
are skipped; `~` / `null` / empty value normalize to null.

Generalizes the single-key stack walker from scripts/bash/pro-report.sh
(report_config_get) into a full-document walk.

Exit codes: 0 always by default (log-not-fatal). With --strict: 1 when any
mismatch OR any parse failure. Per the spec edge case, a parse failure means
the check NEVER claims "no drift" — the summary says UNVERIFIED instead.
"""
import argparse
import os
import re
import subprocess
import sys

# Block-scalar indicators: |, >, optionally with chomping/indent modifiers.
_BLOCK_RE = re.compile(r"^[|>][+-]?[0-9]*$")


class ParseFailure(Exception):
    """Raised when a source file cannot be read or parsed (reason only —
    the reporting site prefixes the file path)."""


def strip_comment(line):
    """Drop a trailing `# comment`, respecting single/double quotes.

    A `#` starts a comment only outside quotes and at line start or after
    whitespace (YAML rule) — so `"#fff"` or `key#x` never get truncated.
    """
    quote = None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = None
        elif ch in ("'", '"'):
            quote = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i]
    return line


def parse_yaml_subset(text):
    """Flatten a YAML-subset document into {dotted-path tuple: raw scalar}.

    Stack-based indent walker. Skips list items (marking their parent key so
    it is not mistaken for a null leaf, and discarding any keys nested inside
    list items) and block-scalar bodies. A key with an empty value is a null
    leaf unless later lines prove it is a mapping parent.
    """
    entries = []        # (path_tuple, raw_value) in document order
    list_parents = set()
    stack = []          # [(indent, key)]
    block_indent = None  # indent of the key that opened a block scalar
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = strip_comment(raw).rstrip()
        if not line.strip():
            continue
        stripped = line.lstrip(" ")
        indent = len(line) - len(stripped)
        if "\t" in raw[:len(raw) - len(raw.lstrip())]:
            raise ParseFailure("tab in indentation at line %d" % lineno)
        if block_indent is not None:
            if indent > block_indent:
                continue  # body line of a block scalar — skip
            block_indent = None
        if stripped == "-" or stripped.startswith("- "):
            while stack and stack[-1][0] > indent:
                stack.pop()
            if stack:
                list_parents.add(tuple(k for _, k in stack))
            continue
        if ":" not in stripped:
            continue  # document markers, stray scalars — out of subset, skip
        key, _, value = stripped.partition(":")
        key, value = key.strip(), value.strip()
        if not key:
            continue
        while stack and stack[-1][0] >= indent:
            stack.pop()
        stack.append((indent, key))
        path = tuple(k for _, k in stack)
        if _BLOCK_RE.match(value):
            block_indent = indent  # block scalar — skip key and its body
            continue
        entries.append((path, value))

    all_paths = set(p for p, _ in entries)

    def is_mapping_parent(path):
        n = len(path)
        return any(len(q) > n and q[:n] == path for q in all_paths)

    def inside_list(path):
        return any(path[:len(lp)] == lp for lp in list_parents)

    leaves = {}
    for path, value in entries:
        if inside_list(path) or is_mapping_parent(path):
            continue
        leaves[path] = value  # duplicates: last occurrence wins
    return leaves


def normalize(value):
    """Canonical scalar form: strip quotes; lowercase booleans; null-ify."""
    v = value.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
        v = v[1:-1]
    if v == "" or v == "~" or v.lower() == "null":
        return "null"
    if v.lower() in ("true", "false"):
        return v.lower()
    return v


def load_flat(path):
    """Read + parse one file → {dotted-path string: normalized scalar}."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError) as e:
        raise ParseFailure(str(e))
    leaves = parse_yaml_subset(text)
    return {".".join(p): normalize(v) for p, v in leaves.items()}


def load_extension_defaults(path):
    """extension.yml → only the `defaults:` subtree, paths relative to it."""
    flat = load_flat(path)
    out = {k[len("defaults."):]: v for k, v in flat.items()
           if k.startswith("defaults.")}
    if not out:
        raise ParseFailure("no keys under top-level 'defaults:'")
    return out


def repo_root():
    """Git toplevel when available, else cwd — mirrors sibling scripts."""
    try:
        res = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, check=False)
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip()
    except OSError:
        pass
    return os.getcwd()


def main():
    ap = argparse.ArgumentParser(
        description="Detect default-value drift between extension.yml "
                    "(defaults:) and pro-config.template.yml (FR-013).")
    ap.add_argument("--extension", default=None,
                    help="path to extension.yml (default: <repo-root>/extension.yml)")
    ap.add_argument("--template", default=None,
                    help="path to pro-config.template.yml (default: <repo-root>/pro-config.template.yml)")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 on any mismatch or parse failure (default: always exit 0)")
    args = ap.parse_args()

    root = repo_root()

    def first_existing(candidates):
        """First existing path, else the first candidate (its parse failure names it)."""
        for c in candidates:
            if os.path.isfile(c):
                return c
        return candidates[0]

    # Default paths probe both layouts: the pro SOURCE repo (files at the root)
    # and a CONSUMER project (files under .specify/extensions/pro/).
    ext_path = args.extension or first_existing([
        os.path.join(root, "extension.yml"),
        os.path.join(root, ".specify", "extensions", "pro", "extension.yml"),
    ])
    tpl_path = args.template or first_existing([
        os.path.join(root, "pro-config.template.yml"),
        os.path.join(root, ".specify", "extensions", "pro", "pro-config.template.yml"),
    ])

    parse_failed = False
    ext, tpl = None, None
    try:
        ext = load_extension_defaults(ext_path)
    except ParseFailure as e:
        parse_failed = True
        print("PARSE-FAILURE %s: %s" % (ext_path, e))
    try:
        tpl = load_flat(tpl_path)
    except ParseFailure as e:
        parse_failed = True
        print("PARSE-FAILURE %s: %s" % (tpl_path, e))

    if parse_failed:
        # Never claim clean on unverified input (spec edge case).
        print("drift: UNVERIFIED (parse failure)")
        sys.exit(1 if args.strict else 0)

    shared = sorted(set(ext) & set(tpl))
    only_ext = sorted(set(ext) - set(tpl))
    only_tpl = sorted(set(tpl) - set(ext))

    print("config-defaults drift check (FR-013)")
    print("  extension.yml (defaults: subtree): %s — %d keys" % (ext_path, len(ext)))
    print("  pro-config.template.yml:           %s — %d keys" % (tpl_path, len(tpl)))
    print("")

    mismatches = [p for p in shared if ext[p] != tpl[p]]
    for p in mismatches:
        print("MISMATCH %s: extension.yml=%s template=%s" % (p, ext[p], tpl[p]))
    if mismatches:
        print("")

    if only_ext:
        print("only in extension.yml defaults (informational, NOT counted as mismatches):")
        for p in only_ext:
            print("  %s = %s" % (p, ext[p]))
        print("")
    if only_tpl:
        print("only in pro-config.template.yml (informational, NOT counted as mismatches):")
        for p in only_tpl:
            print("  %s = %s" % (p, tpl[p]))
        print("")

    print("drift: %d mismatch(es) across %d shared keys" % (len(mismatches), len(shared)))
    sys.exit(1 if (args.strict and mismatches) else 0)


if __name__ == "__main__":
    main()
