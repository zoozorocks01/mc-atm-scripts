#!/usr/bin/env bash
# Validate the isolated-staging MEGA Cells steel compression data-map overlay.
set -euo pipefail

file="${1:-staging/kubejs/data/megacells/data_maps/item/compression_overrides.json}"
test -f "$file"

jq -e '
  (type == "object") and
  (has("replace") | not) and
  (.remove? | not) and
  (.values | type == "object") and
  (.values | keys | sort == ["alltheores:steel_ingot", "alltheores:steel_nugget"]) and
  (.values["alltheores:steel_nugget"] == {"variant": "alltheores:steel_ingot"}) and
  (.values["alltheores:steel_ingot"] == {"variant": "alltheores:steel_block"})
' "$file" >/dev/null

echo "PASS: MEGA Cells steel override is additive and maps nugget -> ingot -> block"
