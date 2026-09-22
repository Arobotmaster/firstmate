#!/usr/bin/env bash
# Portable structural validation for the harness-adapters routing artifact.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTER="$ROOT/.agents/skills/harness-adapters/SKILL.md"
TMP_ROOT=$(fm_test_tmproot fm-harness-adapter-references)
ROUTING_JSON="$TMP_ROOT/routing.json"

awk '
  /^```json harness-adapter-routing-v1$/ { capture = 1; next }
  capture && /^```$/ { exit }
  capture { print }
' "$ROUTER" > "$ROUTING_JSON"

jq -e '
  (.operations | type == "object") and
  (.harnesses | type == "object") and
  ([.operations[][] | select(type != "array")] | length == 0) and
  ([.operations[][][] | select(type != "string")] | length == 0) and
  ([.harnesses[] | select(type != "string")] | length == 0)
' "$ROUTING_JSON" >/dev/null || fail "harness adapter routing artifact is not a normalized operation and harness map"

jq -r '.operations[][][], .harnesses[]' "$ROUTING_JSON" | sort -u | while IFS= read -r path; do
  [ -r "$ROOT/.agents/skills/harness-adapters/$path" ] \
    || fail "harness adapter routing target is unreadable: $path"
done
pass "harness adapter routing artifact is normalized and every target is readable"

python3 - "$ROOT/.agents/skills/harness-adapters" <<'PY' \
  || fail "harness adapter code-marked owner paths must resolve from the skill directory"
import re
import sys
from pathlib import Path

skill = Path(sys.argv[1]).resolve()
invalid = []
for reference in sorted((skill / "references").rglob("*.md")):
    for line_number, line in enumerate(reference.read_text(encoding="utf-8").splitlines(), 1):
        for span in re.findall(r"`([^`\n]+)`", line):
            path = span.split()[0].split("#", 1)[0].rstrip(".,:;")
            if not (path.startswith("../") or path.startswith("references/")):
                continue
            if not (skill / path).exists():
                invalid.append(f"{reference.relative_to(skill)}:{line_number}: {path}")

if invalid:
    print("\n".join(invalid), file=sys.stderr)
    raise SystemExit(1)
PY
pass "nested harness references resolve code-marked owner paths from the skill directory"
