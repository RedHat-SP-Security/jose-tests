#!/usr/bin/env python3
"""Verify that the expected PQC KEM Meson tests are present and passed."""

import json
import pathlib
import sys

test_log = pathlib.Path(sys.argv[1])
require_tests = sys.argv[2].lower() in {"1", "yes", "true"}
expected_tests = {"alg_kem", "jose-jwk-encap", "jose-jwk-decap"}

if not test_log.is_file():
    if require_tests:
        print(f"Required Meson test log is missing: {test_log}", file=sys.stderr)
        sys.exit(1)
    print(f"Meson test log is unavailable; skipping optional KEM checks: {test_log}")
    sys.exit(0)

try:
    log_content = test_log.read_text()
except OSError as error:
    print(f"Unable to read Meson test log {test_log}: {error}", file=sys.stderr)
    sys.exit(1)

try:
    entries = json.loads(log_content)
except json.JSONDecodeError:
    # Meson versions may write either a JSON array or one JSON object per line.
    try:
        entries = [json.loads(line) for line in log_content.splitlines() if line.strip()]
    except json.JSONDecodeError as error:
        print(f"Unable to parse Meson test log {test_log}: {error}", file=sys.stderr)
        sys.exit(1)

if isinstance(entries, dict):
    entries = [entries]

if not isinstance(entries, list):
    print("Unexpected Meson test log format: expected a list", file=sys.stderr)
    sys.exit(1)

results = {}
for entry in entries:
    if isinstance(entry, dict) and entry.get("name") in expected_tests:
        results.setdefault(entry["name"], []).append(entry.get("result"))

found_tests = set(results)
if not found_tests and not require_tests:
    print("KEM tests are not present in this jose source; skipping optional KEM checks")
    sys.exit(0)

missing_tests = expected_tests - found_tests
if missing_tests:
    print("Missing required KEM tests: " + ", ".join(sorted(missing_tests)), file=sys.stderr)
    sys.exit(1)

failed = False
for name in sorted(expected_tests):
    statuses = results[name]
    if statuses != ["OK"]:
        print(f"KEM test {name} did not pass exactly once (results: {statuses})", file=sys.stderr)
        failed = True
    else:
        print(f"KEM test passed: {name}")

sys.exit(1 if failed else 0)
