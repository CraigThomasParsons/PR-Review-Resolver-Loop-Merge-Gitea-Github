#!/usr/bin/env bash
# Offline cases for agent-pool/scripts/gates.py, issue #14, docs/plans/controller-gates.md:
# the pinned manifest (load/validate/select/protected), the diff and receipt helpers the
# controller uses, and the sandboxed runner (`run`). The runner's real-sandbox cases need an
# unprivileged bwrap and a systemd user manager; without them (or with
# AGENT_POOL_TEST_REAL_SANDBOX=0) they are reported as SKIP and counted, never passed. They talk
# only to a loopback listener this script opens and to fixture credentials in a temp HOME.
# The end-to-end controller path (prod-common.sh run_gates) is in verify-providers.sh.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
GATES="$ROOT/agent-pool/scripts/gates.py"
TMP="$(mktemp -d)"
cleanup() {
  local pid
  while read -r pid; do kill "$pid" 2>/dev/null; done < <(cat "$TMP/pids" 2>/dev/null)
  chmod -R u+w "$TMP" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0; fail=0; skipped=0
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

cat > "$TMP/unnormalised-cwd.toml" <<'EOF'
version = 1
[[gate]]
name = "x"
cwd = "./a//b"
argv = ["npm", "test"]
paths = ["**"]
EOF
out="$(validate "$TMP/unnormalised-cwd.toml" 2>&1)"
expect "cwd=./a//b that is not normalised" "$out" "must be normalised"

cat > "$TMP/defaults-not-table.toml" <<'EOF'
version = 1
defaults = 5
gate = 7
EOF
out="$(validate "$TMP/defaults-not-table.toml" 2>&1)"; rc=$?
expect "a non-table defaults is reported, not a traceback" "$out" "defaults: must be a table"
expect "a non-array gate is reported too" "$out" "gate: must be an array of tables"
expect_not "and nothing crashes" "$out" "Traceback"
expect "still exits 2" "$rc" "2"

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
OVERRIDE_SHA="$(git hash-object --no-filters "$TMP/gatesdir/owner__repo.toml")"
expect "and its blob is the override file's own blob SHA" "$out" "\"blob\": \"$OVERRIDE_SHA\""

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

printf '{"source": "none", "blob": "", "manifest": null}' > "$TMP/none.json"
out="$(protected "$TMP/none.json" "$(changed_file .agent-pool-context.md README.md)" 2>&1)"
expect "load's no-manifest output still applies the built-in protections" "$out" ".agent-pool-context.md"
expect_not "without crashing" "$out" "Traceback"
out="$(select_gates "$TMP/none.json" "$(changed_file README.md)" 2>&1)"
expect "and select on it prints none" "$out" "none"

# ---------------------------------------------------------------- sandbox limits
echo "validate rejects sandbox limits that are not plain values (they become systemd-run -p arguments)"
cat > "$TMP/bad-limits.toml" <<'EOF'
version = 1
[defaults]
memory = "4G -p ExecStartPre=/bin/evil"
cpu    = "lots"
tasks  = 0
EOF
out="$(validate "$TMP/bad-limits.toml" 2>&1)"
expect "a memory value with anything but a size" "$out" "defaults.memory: must be a string like 4G"
expect "a cpu value that is not a percentage" "$out" "defaults.cpu: must be a string like 200%"
expect "a task limit that is not positive" "$out" "defaults.tasks: must be a positive integer"

# ---------------------------------------------------------------- changes / docs-only
echo "changes splits diff-tree output into changed paths and gitlinks"
CH="$TMP/changes-repo"
git init -q "$CH"
git -C "$CH" -c user.email=t@e -c user.name=t commit -q --allow-empty -m base
CH_BASE="$(git -C "$CH" rev-parse HEAD)"
mkdir -p "$CH/docs"; echo a > "$CH/a.txt"; echo d > "$CH/docs/x.md"; echo s > "$CH/sp ace.txt"
git -C "$CH" add a.txt docs/x.md "sp ace.txt"
git -C "$CH" update-index --add --cacheinfo "160000,$CH_BASE,vendor/sub"
git -C "$CH" -c user.email=t@e -c user.name=t commit -q -m change
git -C "$CH" diff-tree -r -z --no-renames --raw "$CH_BASE" HEAD > "$TMP/raw"
python3 "$GATES" changes --raw "$TMP/raw" --changed-out "$TMP/raw.changed" --gitlinks-out "$TMP/raw.gitlinks"
expect "exits 0" "$?" "0"
out="$(tr '\0' '\n' < "$TMP/raw.changed")"
expect "every changed path is listed" "$out" "a.txt"
expect "a path with a space survives intact" "$out" "sp ace.txt"
expect "the gitlink is a changed path" "$out" "vendor/sub"
out="$(tr '\0' '\n' < "$TMP/raw.gitlinks")"
expect "and the only gitlink" "$out" "vendor/sub"
expect_not "a plain file is not a gitlink" "$out" "a.txt"
out="$(protected "$TMP/example.json" "$TMP/raw.changed" "$TMP/raw.gitlinks")"
expect "the gitlink from a real diff is protected" "$out" "vendor/sub"

python3 "$GATES" docs-only --changed "$(changed_file README.md docs/a/b.md)"
expect "docs-only: markdown and docs/** only" "$?" "0"
python3 "$GATES" docs-only --changed "$(changed_file README.md src/x.py)"
expect "docs-only: not with a code path" "$?" "1"
: > "$TMP/empty-changed"
python3 "$GATES" docs-only --changed "$TMP/empty-changed"
expect "docs-only: not for an empty change" "$?" "1"

# ---------------------------------------------------------------- receipts
echo "receipts are write-once and bound to one attempt and one head"
ST="$TMP/state"
H1=1111111111111111111111111111111111111111; H2=2222222222222222222222222222222222222222
receipt() { # attempt head result
  python3 "$GATES" receipt --state "$ST" --repo owner/repo --pr 7 --attempt "$1" --provider claude \
    --base-sha "$H2" --pr-head "$H2" --head "$2" --source base --blob abc123 --result "$3" 2>&1
}
out="$(receipt att-a "$H1" pass)"; rc=$?
expect "the first receipt is written" "$rc" "0"
expect "at the attempt's path" "$out" "gates/owner_repo__7__att-a.json"
expect "read-only" "$(stat -c %a "$ST/gates/owner_repo__7__att-a.json")" "444"
expect "with a by-head copy" "$(cat "$ST/gates/by-head/owner_repo__7__$H1.json")" '"attempt_id": "att-a"'
out="$(receipt att-a "$H1" gate-fail)"; rc=$?
expect "a second receipt for the same attempt is refused (exit 3)" "$rc" "3"
expect "saying so" "$out" "never rewritten"
expect "and the first one is unchanged" "$(cat "$ST/gates/owner_repo__7__att-a.json")" '"result": "pass"'
check() { python3 "$GATES" check-receipt --state "$ST" --repo owner/repo --pr 7 --attempt "$1" --head "$2" 2>&1; }
check att-a "$H1" >/dev/null
expect "check-receipt passes the attempt at its own head" "$?" "0"
out="$(check att-a "$H2")"; rc=$?
expect "but not at any other head" "$rc" "1"
expect "naming the mismatch" "$out" "not att-a at $H2"
check att-z "$H1" >/dev/null
expect "nor for another attempt" "$?" "1"
receipt att-b "$H2" gate-fail >/dev/null
out="$(check att-b "$H2")"; rc=$?
expect "nor for a receipt that did not pass" "$rc" "1"
expect "saying why" "$out" "result is gate-fail"

printf '## Automated resolve\nFixed: 1\n<!-- pulse-resolve:v1 head=%s reviewed=%s fixed=1 noted=0 deferred=0 -->\n' "$H1" "$H2" > "$TMP/report.md"
python3 "$GATES" annotate --report "$TMP/report.md" --receipt "$ST/gates/owner_repo__7__att-a.json" --out "$TMP/report.gated"
body="$(cat "$TMP/report.gated")"
expect "annotate adds the gate section" "$body" "### Gates (run by the pool controller)"
expect "and the gate marker before the resolve marker" "${body%%pulse-resolve*}" "agent-pool-gates:v1 head=$H1 manifest=abc123 result=pass"
expect "keeping the resolve marker as the last line" "$(tail -1 "$TMP/report.gated")" "pulse-resolve:v1 head=$H1"
expect "keeping the worker's text" "$body" "Fixed: 1"

# ---------------------------------------------------------------- run: refusals before any sandbox
echo "run fails closed (infra) before running anything"
FAKEHOME="$TMP/fakehome"
mkdir -p "$FAKEHOME/.ssh" "$FAKEHOME/.config/tea" "$TMP/tc/bin" "$TMP/gd" "$TMP/runs"
echo "-----BEGIN OPENSSH PRIVATE KEY----- fixture" > "$FAKEHOME/.ssh/id_test"
echo "token: fixture-tea-token" > "$FAKEHOME/.config/tea/config.yml"
echo g > "$TMP/select"
gate_manifest() { # argv-json [extra top-level json]
  printf '{"version": 1, "defaults": {"timeout": 3, "budget": 20, "memory": "64M"}, "gate": [{"name": "g", "argv": %s, "paths": ["**"]}]%s}' \
    "$1" "${2:-}" > "$TMP/run-manifest.json"
}
run_gate() { # tag [VAR=value...]: run the manifest in $TMP/run-manifest.json against $TMP/gd
  local tag="$1"; shift
  env HOME="$FAKEHOME" GITEA_TOKEN=fixture-gitea-token-123456 SSH_AUTH_SOCK="$TMP/agent.sock" \
    AGENT_POOL_GATE_RO_BINDS="$TMP/tc" "$@" python3 "$GATES" run --manifest "$TMP/run-manifest.json" \
    --gate-dir "$TMP/gd" --select "$TMP/select" --runs "$TMP/runs" --tag "$tag" --budget "${BUDGET:-20}" \
    --lock "$TMP/gates.lock" 2>&1
}
gate_manifest '["just", "env"]'
out="$(run_gate nobwrap AGENT_POOL_GATE_SANDBOX=/nonexistent/bwrap)"
expect "a missing bwrap is infra" "$out" '"result": "infra"'
expect "saying gates never run unsandboxed" "$out" "bwrap is unavailable (/nonexistent/bwrap); gates never run unsandboxed"
out="$(run_gate noscope AGENT_POOL_GATE_SCOPE=/nonexistent/systemd-run)"
expect "a missing systemd-run is infra" "$out" "systemd-run is unavailable"
# A present-but-unusable tool still passes the existence check; the refusals below come first.
NOOP=(AGENT_POOL_GATE_SANDBOX=/bin/true AGENT_POOL_GATE_SCOPE=/bin/true)
out="$(run_gate home "${NOOP[@]}" AGENT_POOL_GATE_RO_BINDS="$FAKEHOME")"
expect "a toolchain bind of \$HOME is infra" "$out" "is \$HOME or a parent of it"
out="$(run_gate parent "${NOOP[@]}" AGENT_POOL_GATE_RO_BINDS="$TMP")"
expect "and so is a parent of \$HOME" "$out" "is \$HOME or a parent of it"
mkdir -p "$FAKEHOME/.config/sometool"
out="$(run_gate cfg "${NOOP[@]}" AGENT_POOL_GATE_RO_BINDS="$FAKEHOME/.config/sometool")"
expect "and anything under a credential directory" "$out" "overlaps $FAKEHOME/.config"
out="$(run_gate rel "${NOOP[@]}" AGENT_POOL_GATE_RO_BINDS="tc")"
expect "and a relative path" "$out" "is not an absolute path"
gate_manifest '["just", "env"]' ', "deps": [{"name": "d", "lockfile": "package-lock.json", "install": ["npm", "ci"]}]'
out="$(run_gate deps "${NOOP[@]}")"
expect "a manifest with [[deps]] is infra until the dependency cache exists" "$out" "declares [[deps]]"
gate_manifest '["sh", "-c", "true"]'
out="$(run_gate badargv "${NOOP[@]}")"
expect "run re-validates the manifest it is given" "$out" "the manifest fails validation"
gate_manifest '["just", "env"]'
echo nosuch > "$TMP/select"
out="$(run_gate unknown "${NOOP[@]}")"
expect "a selected gate missing from the manifest is infra" "$out" "no gate named 'nosuch'"
echo g > "$TMP/select"
mkdir -p "$TMP/gd/.git"
out="$(run_gate gitdir "${NOOP[@]}")"
expect "a gate checkout that has a .git is infra" "$out" "is a git checkout"
rmdir "$TMP/gd/.git"

# ---------------------------------------------------------------- run: the real sandbox
echo "run in the real sandbox (bwrap inside a systemd user scope)"
real_sandbox_ok() {
  [ "${AGENT_POOL_TEST_REAL_SANDBOX:-1}" != 0 ] || { echo "AGENT_POOL_TEST_REAL_SANDBOX=0"; return 1; }
  command -v bwrap >/dev/null && command -v systemd-run >/dev/null || { echo "bwrap or systemd-run missing"; return 1; }
  systemd-run --user --scope --quiet --collect true >/dev/null 2>&1 || { echo "no usable systemd user manager"; return 1; }
  bwrap --unshare-all --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib /lib64 \
    --proc /proc --dev /dev /usr/bin/true >/dev/null 2>&1 || { echo "unprivileged bwrap --unshare-all does not work here"; return 1; }
}
if why="$(real_sandbox_ok)"; then
  python3 - "$TMP/port" "$TMP/connections" <<'PY' &
import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(5)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    c, _ = s.accept(); open(sys.argv[2], "a").write("connected\n"); c.close()
PY
  echo $! >> "$TMP/pids"
  for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
  cat > "$TMP/tc/bin/just" <<SH
#!/bin/sh
case "\$1" in
  env)   env | sort; echo "HOMELS=\$(ls -A ~ | tr '\n' ' ')"
         [ -e /run/user/$(id -u) ] && echo RUNUSER=present
         [ -e "$FAKEHOME/.ssh/id_test" ] && echo SSHKEY=visible
         [ -e "$FAKEHOME/.config/tea/config.yml" ] && echo TEA=visible ;;
  net)   python3 -c 'import socket
try: socket.create_connection(("127.0.0.1", $(cat "$TMP/port")), timeout=2); print("NET=connected")
except OSError as e: print("NET=blocked", e)' ;;
  write) touch "$TMP/outside-write" 2>/dev/null && echo OUTSIDE=wrote
         echo x > /work/inside && echo INSIDE=wrote
         touch /usr/gate-write 2>/dev/null && echo USR=wrote ;;
  both)  echo out-1; echo err-1 >&2; echo out-2; echo err-2 >&2 ;;
  argv)  shift; printf 'ARG=%s\n' "\$@" ;;
  sleep) sleep 30 ;;
  hog)   exec python3 -c "x = b'a' * (300 * 1024 * 1024); import time; time.sleep(2)" ;;
  fail)  echo "red"; exit 3 ;;
esac
exit 0
SH
  chmod +x "$TMP/tc/bin/just"
  log_of() { cat "$TMP/runs/gate-$1-g.log" 2>/dev/null; }

  gate_manifest '["just", "env"]'
  out="$(run_gate env)"
  expect "a gate that only reads its env passes" "$out" '"result": "pass"'
  expect_not "it never sees the Gitea token" "$(log_of env)" "GITEA_TOKEN"
  expect_not "nor its value" "$(log_of env)" "fixture-gitea-token"
  expect_not "nor the ssh agent socket" "$(log_of env)" "SSH_AUTH_SOCK"
  expect_not "nor the user bus" "$(log_of env)" "DBUS_SESSION_BUS_ADDRESS"
  expect_not "nor XDG_RUNTIME_DIR" "$(log_of env)" "XDG_RUNTIME_DIR"
  expect "its HOME is the sandbox's own" "$(log_of env)" "HOME=/home/gate"
  expect "and empty" "$([ "$(log_of env | grep '^HOMELS=')" = "HOMELS=" ] && echo empty || echo not-empty)" "empty"
  expect_not "the real home's ssh key does not exist inside" "$(log_of env)" "SSHKEY=visible"
  expect_not "nor its tea config" "$(log_of env)" "TEA=visible"
  expect_not "/run/user (the agent socket) is not mounted" "$(log_of env)" "RUNUSER=present"

  gate_manifest '["just", "net"]'
  out="$(run_gate net)"
  expect "a connect to a host loopback listener fails inside" "$(log_of net)" "NET=blocked"
  expect "and the listener saw nothing" "$(cat "$TMP/connections" 2>/dev/null || echo none)" "none"

  gate_manifest '["just", "write"]'
  out="$(run_gate write)"
  expect "a write outside /work never reaches the host" "$([ -e "$TMP/outside-write" ] && echo wrote || echo absent)" "absent"
  expect_not "/usr is read-only" "$(log_of write)" "USR=wrote"
  expect "the gate checkout itself is writable" "$(cat "$TMP/gd/inside" 2>/dev/null)" "x"

  gate_manifest '["just", "both"]'
  out="$(run_gate both)"
  expect "both fds go to one log in arrival order" "$(log_of both | tr '\n' '|')" "out-1|err-1|out-2|err-2|"

  gate_manifest '["just", "argv", "$HOME", "${GITEA_TOKEN}"]'
  out="$(run_gate argv)"
  expect "argv reaches the gate unexpanded" "$(log_of argv | tr '\n' '|')" 'ARG=$HOME|ARG=${GITEA_TOKEN}|'

  gate_manifest '["just", "fail"]'
  out="$(run_gate fail)"
  expect "a gate exiting non-zero is gate-fail" "$out" '"result": "gate-fail"'
  expect "naming the gate and its exit" "$out" "gate 'g' exited 3"
  expect "with a per-gate record on disk" "$(cat "$TMP/runs/gate-fail-g.json")" '"exit_code": 3'

  gate_manifest '["just", "sleep"]'
  t0=$(date +%s); out="$(run_gate sleep)"; took=$(( $(date +%s) - t0 ))
  expect "a gate past its timeout is gate-timeout" "$out" '"result": "gate-timeout"'
  expect "after its own timeout" "$out" "timed out after 3s"
  expect "promptly" "$([ "$took" -lt 15 ] && echo prompt || echo "slow ${took}s")" "prompt"

  gate_manifest '["just", "hog"]'
  out="$(run_gate hog)"
  expect "a gate over MemoryMax is gate-resource" "$out" '"result": "gate-resource"'

  gate_manifest '["vendor/bin/phpunit"]'
  out="$(run_gate missing)"
  expect "a runner that is not in the tree is infra, not a gate failure" "$out" '"result": "infra"'
  if [ ! -e /usr/bin/just ] && [ ! -e /bin/just ]; then
    gate_manifest '["just", "env"]'
    out="$(run_gate nopath AGENT_POOL_GATE_RO_BINDS=)"
    expect "a runner not on the sandbox PATH is infra" "$out" "is not on the sandbox PATH"
  fi

  printf '#!/bin/sh\necho "bwrap: setting up uid map: Permission denied" >&2\nexit 1\n' > "$TMP/broken-bwrap"
  chmod +x "$TMP/broken-bwrap"
  gate_manifest '["just", "env"]'
  out="$(run_gate broken AGENT_POOL_GATE_SANDBOX="$TMP/broken-bwrap")"
  expect "a bwrap that cannot start is infra" "$out" '"result": "infra"'
  expect "saying the sandbox did not start" "$out" "the sandbox did not start"

  out="$(BUDGET=0 run_gate nobudget)"
  expect "a gate with no budget left never starts" "$out" "never started: the job's gate budget ran out"
  expect "and is gate-timeout" "$out" '"result": "gate-timeout"'

  flock "$TMP/gates.lock" sleep 8 & echo $! >> "$TMP/pids"
  sleep 0.5
  out="$(BUDGET=2 run_gate locked)"
  expect "the host-wide gate lock's wait counts against the budget" "$out" "ran out waiting for the host-wide gate lock"
else
  skipped=$((skipped + 1)); printf '  SKIP  real sandbox cases: %s\n' "$why"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
