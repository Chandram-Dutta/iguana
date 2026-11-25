#!/bin/bash
# Run the tests and say how much of the code they run, part by part:
#
#   scripts/coverage.sh            the table
#   scripts/coverage.sh --files    every file as well, least covered first
#   scripts/coverage.sh --check    also fail when a part has fallen below its floor
#   scripts/coverage.sh --report-only   do not run the tests; read what the last
#                                       `swift test --enable-code-coverage` left behind
#
# The floors are for the parts that can be tested without a screen: the pure logic in
# IguanaCore, and the window manager, which runs against a made-up Mac in the tests
# (Tests/IguanaAppTests/Support). The views and the code that talks to macOS itself are
# counted and shown, and have no floor.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ " $* " != *" --report-only "* ]]; then
  log="$(mktemp)"
  if ! swift test --enable-code-coverage >"$log" 2>&1; then
    grep -E "error|failed" "$log" | sort -u | tail -40
    echo "the tests failed; the whole output is in $log" >&2
    exit 1
  fi
  # One line for each of the two test bundles.
  grep -A1 "Test Suite 'All tests'" "$log" | grep -E "Executed [0-9]+ tests" | sort -u
  rm -f "$log"
fi
report="$(swift test --show-codecov-path)"

python3 - "$report" "$@" <<'PY'
import json, sys

report, flags = sys.argv[1], sys.argv[2:]
# part of the tree, the least it may be covered (percent of lines), or None for no floor
PARTS = [
    ("IguanaCore/", 95),
    ("iguana/Manager/", 95),
    ("iguana/Platform/", None),
    ("iguana/", None),
]

files = []
for f in json.load(open(report))["data"][0]["files"]:
    name = f["filename"]
    if "/Sources/" not in name:
        continue
    lines = f["summary"]["lines"]
    files.append((name.split("/Sources/")[1], lines["count"], lines["covered"]))

if "--files" in flags:
    for name, count, covered in sorted(files, key=lambda r: r[2] / max(r[1], 1)):
        print(f"{name:58s} {count:6d} lines {100 * covered / max(count, 1):6.1f}%")
    print()

failed = False
print(f"{'part':28s} {'lines':>7s} {'covered':>8s}  floor")
for prefix, floor in PARTS:
    count = sum(c for n, c, _ in files if n.startswith(prefix))
    covered = sum(v for n, _, v in files if n.startswith(prefix))
    percent = 100 * covered / max(count, 1)
    low = floor is not None and percent < floor
    failed = failed or low
    print(f"{'Sources/' + prefix:28s} {count:7d} {percent:7.1f}%  {'' if floor is None else str(floor) + '%'}{'   BELOW ITS FLOOR' if low else ''}")
count = sum(c for _, c, _ in files)
covered = sum(v for _, _, v in files)
print(f"{'everything':28s} {count:7d} {100 * covered / max(count, 1):7.1f}%")

if "--check" in flags and failed:
    sys.exit("coverage has fallen below a floor; add tests for what was added")
PY
