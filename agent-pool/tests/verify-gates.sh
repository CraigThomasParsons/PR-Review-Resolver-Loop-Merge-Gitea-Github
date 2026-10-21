#!/usr/bin/env bash
# Offline cases for the pinned gate manifest (agent-pool/scripts/gates.py), issue #14,
# docs/plans/controller-gates.md Section 1. This covers load/validate/select/protected only;
# the sandboxed runner (`gates.py run`, Section 2) is a later step and has its own suite.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
GATES="$ROOT/agent-pool/scripts/gates.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
expect() { # name got wanted-substring
  if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         wanted *%s*\n         got %s\n' "$1" "$3" "$2"; fi
}
expect_not() { # name got unwanted-substring
  if [[ "$2" != *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         did not want *%s*\n         got %s\n' "$1" "$3" "$2"; fi
}

validate() { python3 "$GATES" validate --file "$1"; } # prints stderr+stdout combined by caller
load() { python3 "$GATES" load --main "$1" --base-sha "$2" --repo "$3" 2>&1; }
select_gates() { python3 "$GATES" select --manifest "$1" --changed "$2"; }
protected() { python3 "$GATES" protected --manifest "$1" --changed "$2" ${3:+--gitlinks "$3"}; }
changed_file() { printf '%s\n' "$@" > "$TMP/changed"; echo "$TMP/changed"; }
manifest_json() { # toml-file -> json-file holding {"manifest": ...}
  python3 -c '
import json, sys, tomllib
json.dump({"manifest": tomllib.load(open(sys.argv[1], "rb"))}, open(sys.argv[2], "w"))
' "$1" "$2"
}

EXAMPLE="$ROOT/agent-pool/config/gates.example.toml"

# ---------------------------------------------------------------- validate
echo "validate rejects each known violation"

cat > "$TMP/shell-string.toml" <<'EOF'
version = 1
[[gate]]
name = "x"
argv = "npm test"
paths = ["**"]
EOF
out="$(validate "$TMP/shell-string.toml" 2>&1)"; rc=$?
expect "a shell string instead of argv list" "$out" "must be a non-empty list of strings"
expect "exits 2" "$rc" "2"

cat > "$TMP/argv-sh.toml" <<'EOF'
version = 1
[[gate]]
name = "x"
argv = ["sh", "-c", "true"]
paths = ["**"]
EOF
out="$(validate "$TMP/argv-sh.toml" 2>&1)"
expect "argv[0]=sh is outside GATE_RUNNERS" "$out" "outside GATE_RUNNERS"
expect "and flagged as an interpreter" "$out" "looks like an interpreter"

cat > "$TMP/unknown-key.toml" <<'EOF'
version = 1
nonsense = true
[[gate]]
name = "x"
argv = ["npm", "test"]
paths = ["**"]
EOF
out="$(validate "$TMP/unknown-key.toml" 2>&1)"
expect "an unknown top-level key" "$out" "unknown key 'nonsense'"

cat > "$TMP/bad-cwd.toml" <<'EOF'
version = 1
[[gate]]
name = "x"
cwd = "../x"
argv = ["npm", "test"]
paths = ["**"]
EOF
out="$(validate "$TMP/bad-cwd.toml" 2>&1)"
expect "cwd=../x escaping the tree" "$out" "must be a relative path inside the tree"

cat > "$TMP/over-budget.toml" <<'EOF'
version = 1
[defaults]
budget = 100
[[gate]]
name = "x"
timeout = 200
argv = ["npm", "test"]
paths = ["**"]
EOF
out="$(validate "$TMP/over-budget.toml" 2>&1)"
expect "a per-gate timeout above the manifest's budget" "$out" "timeout 200 exceeds the manifest's budget 100"

cat > "$TMP/argv0-outside.toml" <<'EOF'
version = 1
[[gate]]
name = "x"
argv = ["rustc", "test"]
paths = ["**"]
EOF
out="$(validate "$TMP/argv0-outside.toml" 2>&1)"
expect "an argv[0] outside GATE_RUNNERS" "$out" "'rustc' is outside GATE_RUNNERS"

validate "$EXAMPLE" > /dev/null 2>"$TMP/example.err"
expect "the shipped example manifest itself validates clean" "$(cat "$TMP/example.err")" ""

# ---------------------------------------------------------------- load
echo "load reads only the base blob, by SHA, never the worktree or PR head"

REPO="$TMP/repo"
mkdir -p "$REPO/.agent-pool"
git -C "$REPO" init -q -b master 2>/dev/null || (mkdir -p "$REPO" && git -C "$REPO" init -q && git -C "$REPO" checkout -q -b master)
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
cp "$EXAMPLE" "$REPO/.agent-pool/gates.toml"
git -C "$REPO" add .agent-pool/gates.toml
git -C "$REPO" commit -q -m base
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"
BLOB_SHA="$(git -C "$REPO" rev-parse "HEAD:.agent-pool/gates.toml")"

# Dirty the worktree's own copy after the commit: load must not see this.
printf 'this is not valid toml {{{' > "$REPO/.agent-pool/gates.toml"

out="$(load "$REPO" "$BASE_SHA" owner/repo)"
expect "source is base" "$out" '"source": "base"'
expect "the receipt's blob SHA equals the base commit's blob" "$out" "\"blob\": \"$BLOB_SHA\""
expect "the worktree's dirtied copy is ignored" "$out" '"name": "client"'

rm -rf "$TMP/gatesdir"; mkdir -p "$TMP/gatesdir"
cat > "$TMP/gatesdir/owner__repo.toml" <<'EOF'
version = 1
[[gate]]
name = "override-gate"
argv = ["npm", "test"]
paths = ["**"]
EOF
out="$(AGENT_POOL_GATES_DIR="$TMP/gatesdir" load "$REPO" "$BASE_SHA" owner/repo)"
expect "an override file wins over the base file" "$out" '"source": "override"'
expect "and its own gate is the one returned" "$out" "override-gate"

EMPTY="$TMP/empty-repo"
mkdir -p "$EMPTY"
git -C "$EMPTY" init -q -b master 2>/dev/null || (git -C "$EMPTY" init -q && git -C "$EMPTY" checkout -q -b master)
git -C "$EMPTY" config user.email test@example.com
git -C "$EMPTY" config user.name test
git -C "$EMPTY" commit -q --allow-empty -m empty
EMPTY_SHA="$(git -C "$EMPTY" rev-parse HEAD)"
out="$(load "$EMPTY" "$EMPTY_SHA" owner/repo)"
expect "no manifest at all reports source none" "$out" '"source": "none"'
expect "with a null manifest" "$out" '"manifest": null'

cat > "$TMP/bad-base.toml" <<'EOF'
version = 1
[[gate]]
name = "x"
argv = ["sh"]
paths = ["**"]
EOF
BADREPO="$TMP/bad-repo"
mkdir -p "$BADREPO/.agent-pool"
git -C "$BADREPO" init -q -b master 2>/dev/null || (git -C "$BADREPO" init -q && git -C "$BADREPO" checkout -q -b master)
git -C "$BADREPO" config user.email test@example.com
git -C "$BADREPO" config user.name test
cp "$TMP/bad-base.toml" "$BADREPO/.agent-pool/gates.toml"
git -C "$BADREPO" add .agent-pool/gates.toml
git -C "$BADREPO" commit -q -m bad
BADREPO_SHA="$(git -C "$BADREPO" rev-parse HEAD)"
out="$(load "$BADREPO" "$BADREPO_SHA" owner/repo)"; rc=$?
expect "an invalid base manifest is an infra fault, exit 2" "$rc" "2"
expect "naming the violation" "$out" "outside GATE_RUNNERS"

# ---------------------------------------------------------------- select
echo "select matches a worker's changed paths against each gate's paths"

manifest_json "$EXAMPLE" "$TMP/example.json"
out="$(select_gates "$TMP/example.json" "$(changed_file clientv2/src/App.tsx README.md)")"
expect "a mixed diff touching clientv2/** selects the client gate" "$out" "client"
expect_not "but not the unrelated net gate" "$out" "net"

out="$(select_gates "$TMP/example.json" "$(changed_file README.md docs/plans/x.md)")"
expect "a docs-only diff selects no gate" "$out" "none"

out="$(select_gates "$TMP/example.json" "$(changed_file net/Program.cs Pulse.sln)")"
expect "a diff touching net/** and *.sln selects the net gate" "$out" "net"

# ---------------------------------------------------------------- protected
echo "protected flags manifest-defining paths the worker must never touch"

out="$(protected "$TMP/example.json" "$(changed_file .agent-pool/gates.toml README.md)")"
expect "editing the manifest itself is protected" "$out" ".agent-pool/gates.toml"
expect_not "an unrelated doc is not" "$out" "README.md"

out="$(protected "$TMP/example.json" "$(changed_file .gitattributes)")"
expect ".gitattributes is protected" "$out" ".gitattributes"

out="$(protected "$TMP/example.json" "$(changed_file .gitmodules)")"
expect ".gitmodules is protected" "$out" ".gitmodules"

out="$(protected "$TMP/example.json" "$(changed_file clientv2/package-lock.json)")"
expect "a [[deps]] lockfile is protected" "$out" "clientv2/package-lock.json"

out="$(protected "$TMP/example.json" "$(changed_file justfile)")"
expect "a manifest-declared protect entry (justfile) is protected" "$out" "justfile"

out="$(protected "$TMP/example.json" "$(changed_file vendor/some-submodule)" "$(changed_file vendor/some-submodule)")"
expect "a gitlink the caller flags via --gitlinks is protected" "$out" "vendor/some-submodule"

out="$(protected "$TMP/example.json" "$(changed_file src/app.py)")"
expect "an unrelated path is not protected" "$out" "none"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
