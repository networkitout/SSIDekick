#!/bin/bash
# Regenerates Support/oui.tsv from the IEEE MA-L registry.
# Output: "<6 hex digit OUI><TAB><organisation name>", sorted by OUI.
# The table is written to a temporary file next to it and moved into place only if it has more than 30000 rows,
# so a failed or truncated download never replaces a good table.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp)"
out="$(mktemp "$root/Support/oui.tsv.XXXXXX")"
trap 'rm -f "$tmp" "$out"' EXIT

curl --fail --silent --show-error --location \
    "https://standards-oui.ieee.org/oui/oui.csv" --output "$tmp"

# Columns: Registry, Assignment, Organization Name, Organization Address (quoted fields may contain commas).
python3 -I - "$tmp" <<'PY' | LC_ALL=C sort > "$out"
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

rows="$(wc -l < "$out" | tr -d ' ')"
if [ "$rows" -le 30000 ]; then
    echo "error: only $rows vendor rows parsed (expected more than 30000); Support/oui.tsv left unchanged." >&2
    exit 1
fi
chmod 644 "$out"
mv -f "$out" "$root/Support/oui.tsv"
echo "Support/oui.tsv: $rows rows"
