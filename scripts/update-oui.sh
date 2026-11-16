#!/bin/bash
# Regenerates Support/oui.tsv from the IEEE MA-L registry.
# Output: "<6 hex digit OUI><TAB><organisation name>", sorted by OUI.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl --fail --silent --show-error --location \
    "https://standards-oui.ieee.org/oui/oui.csv" --output "$tmp"

# Columns: Registry, Assignment, Organization Name, Organization Address (quoted fields may contain commas).
python3 -I - "$tmp" <<'PY' | LC_ALL=C sort > "$root/Support/oui.tsv"
import csv, sys
with open(sys.argv[1], newline="", encoding="utf-8") as f:
    rows = csv.reader(f)
    next(rows, None)  # header
    for row in rows:
        if len(row) < 3:
            continue
        oui = row[1].strip().upper()
        name = " ".join(row[2].replace("\t", " ").split())
        if len(oui) == 6 and name:
            print(f"{oui}\t{name}")
PY
