#!/usr/bin/env python3
"""validate_schemas.py — validate fan-out engine artifacts against their contracts.

Validates Partial Result JSON and telemetry JSONL against the schemas in
specs/001-parallel-analysis-engine/contracts/. Uses `jsonschema` when installed;
otherwise falls back to a lightweight structural check (stdlib only) covering the
required fields and enums — enough to catch the failures that matter for the
fan-out engine (missing provenance, bad status, malformed telemetry).

Usage:
  validate_schemas.py partial-result <file.json> [<file.json> ...]
  validate_schemas.py telemetry <file.jsonl> [...]
  validate_schemas.py --schema-dir <dir> partial-result <file.json>

Exit 0 = all valid; 1 = at least one violation (printed to stderr).
"""
import argparse
import json
import os
import sys

DEFAULT_SCHEMA_DIR = os.path.join(
    "specs", "001-parallel-analysis-engine", "contracts"
)

PARTIAL_KINDS = {"architecture", "dependency", "risk", "hotspot"}
PARTIAL_STATUS = {"complete", "summarized", "failed", "truncated"}
PARTIAL_CONF = {"high", "medium", "low"}
TELEMETRY_EVENTS = {"dispatch", "complete", "fail", "timeout", "tiebreak"}
TELEMETRY_SUBSTRATE = {"in-harness", "cli", "sequential"}


def _try_jsonschema(schema_path, obj):
    """Return (handled, errors). handled=False if jsonschema isn't available."""
    try:
        import jsonschema  # type: ignore
    except Exception:
        return False, []
    with open(schema_path, encoding="utf-8") as fh:
        schema = json.load(fh)
    validator = jsonschema.Draft202012Validator(schema)
    errs = [e.message for e in validator.iter_errors(obj)]
    return True, errs


def _check_partial(obj):
    errs = []
    if not isinstance(obj, dict):
        return ["partial result is not an object"]
    for req in ("portion_id", "status", "findings", "unknowns"):
        if req not in obj:
            errs.append("missing required field: %s" % req)
    if obj.get("status") not in PARTIAL_STATUS:
        errs.append("status %r not in %s" % (obj.get("status"), sorted(PARTIAL_STATUS)))
    if obj.get("status") in ("failed", "truncated") and not obj.get("error"):
        errs.append("status=%s requires non-empty 'error'" % obj.get("status"))
    for i, f in enumerate(obj.get("findings", []) or []):
        if not isinstance(f, dict):
            errs.append("finding[%d] is not an object" % i); continue
        for req in ("kind", "target", "claim", "evidence", "confidence"):
            if req not in f:
                errs.append("finding[%d] missing %s" % (i, req))
        if f.get("kind") not in PARTIAL_KINDS:
            errs.append("finding[%d].kind %r invalid" % (i, f.get("kind")))
        if f.get("confidence") not in PARTIAL_CONF:
            errs.append("finding[%d].confidence %r invalid" % (i, f.get("confidence")))
        ev = f.get("evidence")
        if not isinstance(ev, list) or len(ev) < 1:
            errs.append("finding[%d].evidence must be a non-empty array (provenance, FR-016)" % i)
    return errs


def _check_telemetry(obj):
    errs = []
    if not isinstance(obj, dict):
        return ["telemetry record is not an object"]
    for req in ("ts", "run_id", "event", "substrate"):
        if req not in obj:
            errs.append("missing required field: %s" % req)
    if obj.get("event") not in TELEMETRY_EVENTS:
        errs.append("event %r not in %s" % (obj.get("event"), sorted(TELEMETRY_EVENTS)))
    if obj.get("substrate") not in TELEMETRY_SUBSTRATE:
        errs.append("substrate %r not in %s" % (obj.get("substrate"), sorted(TELEMETRY_SUBSTRATE)))
    return errs


def validate_file(kind, path, schema_dir):
    schema_file = {
        "partial-result": "partial-result.schema.json",
        "telemetry": "telemetry-event.schema.json",
    }[kind]
    schema_path = os.path.join(schema_dir, schema_file)
    checker = {"partial-result": _check_partial, "telemetry": _check_telemetry}[kind]

    records = []
    with open(path, encoding="utf-8") as fh:
        if kind == "telemetry" or path.endswith(".jsonl"):
            for ln, line in enumerate(fh, 1):
                line = line.strip()
                if line:
                    records.append((ln, json.loads(line)))
        else:
            records.append((1, json.load(fh)))

    problems = []
    for ln, obj in records:
        if os.path.isfile(schema_path):
            handled, errs = _try_jsonschema(schema_path, obj)
            if not handled:
                errs = checker(obj)
        else:
            errs = checker(obj)
        for e in errs:
            problems.append("%s:%d  %s" % (path, ln, e))
    return problems


def main():
    ap = argparse.ArgumentParser(description="Validate fan-out artifacts against contracts.")
    ap.add_argument("--schema-dir", default=DEFAULT_SCHEMA_DIR)
    ap.add_argument("kind", choices=["partial-result", "telemetry"])
    ap.add_argument("files", nargs="+")
    args = ap.parse_args()

    all_problems = []
    for f in args.files:
        try:
            all_problems += validate_file(args.kind, f, args.schema_dir)
        except (OSError, ValueError) as e:
            all_problems.append("%s  could not read/parse: %s" % (f, e))

    if all_problems:
        sys.stderr.write("VALIDATION FAILED (%d issue(s)):\n" % len(all_problems))
        for p in all_problems:
            sys.stderr.write("  - %s\n" % p)
        sys.exit(1)
    print("OK: %d file(s) valid against %s schema" % (len(args.files), args.kind))


if __name__ == "__main__":
    main()
