#!/usr/bin/env bash
# Offline cases for nightcrew-issue-hold.py against a loopback fake of TheNightCrew's
# GET /api/repos/{owner}/{repo}/issue-hold (tests/fake-nightcrew.py). No real NightCrew, no real
# token: HOME is a temp directory and every proxy variable is unset.
#
# The contract under test: stdout is exactly "clear" with exit 0 only when an authenticated
# HTTP 200 answer names this repo and carries a boolean held=false. held=true prints "busy" with
# exit 0. Anything else prints "busy" with a nonzero exit, and never forwards the bearer token
# through a redirect or prints it.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/nightcrew-issue-hold.py"
FAKE="$ROOT/tests/fake-nightcrew.py"
TMP="$(mktemp -d)"
PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.config/pulse"
unset NIGHT_CREW_URL AGENT_POOL_NIGHTCREW_URL AGENT_POOL_NIGHTCREW_TOKEN_FILE AGENT_POOL_NIGHTCREW_TIMEOUT
unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY

SECRET="nc-test-token-7f3a9b2e"
TOKEN_FILE="$TMP/worker-token"
printf '%s\n' "$SECRET" > "$TOKEN_FILE"

start_fake() { # name -> sets <name>_URL; scenario $TMP/<name>.json, request log $TMP/<name>.log
  python3 "$FAKE" "$TMP/$1.json" "$TMP/$1.log" "$TMP/$1.port" &
  PIDS+=("$!")
  local i
  for i in $(seq 1 50); do [ -s "$TMP/$1.port" ] && break; sleep 0.1; done
  printf -v "${1}_URL" 'http://127.0.0.1:%s/api' "$(cat "$TMP/$1.port")"
}
start_fake nc
start_fake elsewhere
printf '{"status": 200, "body": "{\\"repo\\": \\"owner/repo\\", \\"held\\": false}"}' > "$TMP/elsewhere.json"

scenario() { # status body [extra-json-fields]
  local extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  python3 - "$TMP/nc.json" "$1" "$2" "$extra" <<'PY'
import json, sys
path, status, body, extra = sys.argv[1:]
doc = {"status": int(status), "body": body}
doc.update(json.loads(extra))
json.dump(doc, open(path, "w"))
PY
  : > "$TMP/nc.log"
}

ALL_OUTPUT="$TMP/all-output"
run_hold() { # [extra args...] -> OUT RC ERR; env from the caller
  OUT="$(python3 "$SCRIPT" --repo "${REPO_ARG-owner/repo}" "$@" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
  printf '%s\n%s\n' "$OUT" "$ERR" >> "$ALL_OUTPUT"
}
hold_with() { # [extra args...] -- the usual explicit URL and token file
  AGENT_POOL_NIGHTCREW_URL="$nc_URL" AGENT_POOL_NIGHTCREW_TOKEN_FILE="$TOKEN_FILE" run_hold "$@"
}
requests() { wc -l < "$TMP/nc.log" 2>/dev/null | tr -d ' '; }

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n         %s\n' "$1" "$2"; }
want() { # name wanted-out wanted-rc   (rc "nonzero" means any nonzero)
  local rc_ok=1
  if [ "$3" = nonzero ]; then [ "$RC" -ne 0 ] || rc_ok=0; else [ "$RC" = "$3" ] || rc_ok=0; fi
  if [ "$OUT" = "$2" ] && [ "$rc_ok" = 1 ]; then ok "$1"
  else bad "$1" "wanted out=[$2] rc=$3, got out=[$OUT] rc=$RC err=[$ERR]"; fi
}
same() { # name got wanted
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted [$3], got [$2]"; fi
}

CLEAR='{"repo": "owner/repo", "held": false}'
HELD='{"repo": "owner/repo", "held": true}'

echo "answers from the endpoint"
scenario 200 "$CLEAR"; hold_with
want "held=false on HTTP 200 -> clear, exit 0" clear 0
same "it asks GET <base>/repos/owner/repo/issue-hold" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["path"])' "$TMP/nc.log")" "/api/repos/owner/repo/issue-hold"
same "it sends the Worker token as a bearer" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["authorization"])' "$TMP/nc.log")" "Bearer $SECRET"
same "it asks for JSON" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["accept"])' "$TMP/nc.log")" "application/json"

scenario 200 "$HELD"; hold_with
want "held=true (busy) -> busy, exit 0" busy 0
scenario 200 "$CLEAR"; hold_with
want "the same repo released -> clear on the very next check (no caching)" clear 0

scenario 200 '{"repo": "owner/repo", "held": false, "extra": 1}'; hold_with
want "an extra field does not change a valid answer" clear 0

echo
echo "HTTP errors fail closed, whatever the body says"
for status in 401 403 404 500 502; do
  scenario "$status" "$CLEAR"; hold_with
  want "HTTP $status with a held=false body -> busy, nonzero" busy nonzero
done
scenario 201 "$CLEAR"; hold_with
want "HTTP 201 (not exactly 200) -> busy, nonzero" busy nonzero
scenario 204 ""; hold_with
want "HTTP 204 with no body -> busy, nonzero" busy nonzero

echo
echo "redirects are refused and never carry the bearer"
for status in 301 302 303 307 308; do
  : > "$TMP/elsewhere.log"
  scenario "$status" "" "{\"headers\": {\"Location\": \"$elsewhere_URL/repos/owner/repo/issue-hold\"}}"
  hold_with
  want "HTTP $status to another host -> busy, nonzero" busy nonzero
  same "HTTP $status: the redirect target never received a request" "$(wc -l < "$TMP/elsewhere.log" | tr -d ' ')" "0"
done
scenario 302 "" "{\"headers\": {\"Location\": \"/api/repos/owner/repo/issue-hold?again=1\"}}"
hold_with
want "a same-host redirect is refused too" busy nonzero
same "the same-host redirect was not followed" "$(requests)" "1"

echo
echo "malformed or mismatched payloads fail closed"
check_payload() { # name body
  scenario 200 "$2"; hold_with
  want "$1 -> busy, nonzero" busy nonzero
}
check_payload "not JSON" 'held: false'
check_payload "an empty body" ''
check_payload "truncated JSON" '{"repo": "owner/repo", "held": fal'
check_payload "a JSON list" '[{"repo": "owner/repo", "held": false}]'
check_payload "a JSON string" '"clear"'
check_payload "a different repo" '{"repo": "owner/other", "held": false}'
check_payload "the repo in different case" '{"repo": "Owner/Repo", "held": false}'
check_payload "no repo field" '{"held": false}'
check_payload "a non-string repo" '{"repo": ["owner/repo"], "held": false}'
check_payload "no held field" '{"repo": "owner/repo"}'
check_payload "held as the string \"false\"" '{"repo": "owner/repo", "held": "false"}'
check_payload "held as 0" '{"repo": "owner/repo", "held": 0}'
check_payload "held as null" '{"repo": "owner/repo", "held": null}'
check_payload "an error object" '{"message": "Unauthenticated."}'

echo
echo "credentials and configuration"
scenario 200 "$CLEAR"
AGENT_POOL_NIGHTCREW_URL="$nc_URL" AGENT_POOL_NIGHTCREW_TOKEN_FILE="$TMP/no-such-token" run_hold
want "a missing token file -> busy, nonzero" busy nonzero
same "a missing token file sends no request" "$(requests)" "0"

: > "$TMP/empty-token"
AGENT_POOL_NIGHTCREW_URL="$nc_URL" AGENT_POOL_NIGHTCREW_TOKEN_FILE="$TMP/empty-token" run_hold
want "an empty token file -> busy, nonzero" busy nonzero
printf 'two words\n' > "$TMP/spaced-token"
AGENT_POOL_NIGHTCREW_URL="$nc_URL" AGENT_POOL_NIGHTCREW_TOKEN_FILE="$TMP/spaced-token" run_hold
want "a token with whitespace inside -> busy, nonzero" busy nonzero
same "a bad token sends no request" "$(requests)" "0"

AGENT_POOL_NIGHTCREW_URL="$nc_URL" run_hold
want "no token file at the default path either -> busy, nonzero" busy nonzero
cp "$TOKEN_FILE" "$HOME/.config/pulse/night_crew_token"
AGENT_POOL_NIGHTCREW_URL="$nc_URL" run_hold
want "the default ~/.config/pulse/night_crew_token is read" clear 0
rm -f "$HOME/.config/pulse/night_crew_token"

NIGHT_CREW_URL="$nc_URL" AGENT_POOL_NIGHTCREW_TOKEN_FILE="$TOKEN_FILE" run_hold
want "NIGHT_CREW_URL (the worker client's convention) is honoured" clear 0
NIGHT_CREW_URL="http://127.0.0.1:9/api" AGENT_POOL_NIGHTCREW_URL="$nc_URL" AGENT_POOL_NIGHTCREW_TOKEN_FILE="$TOKEN_FILE" run_hold
want "AGENT_POOL_NIGHTCREW_URL wins over NIGHT_CREW_URL" clear 0
NIGHT_CREW_URL="$nc_URL/" AGENT_POOL_NIGHTCREW_TOKEN_FILE="$TOKEN_FILE" run_hold
want "a trailing slash on the base is tolerated" clear 0

: > "$TMP/nc.log"
AGENT_POOL_NIGHTCREW_URL="file://$TMP/nc.json" AGENT_POOL_NIGHTCREW_TOKEN_FILE="$TOKEN_FILE" run_hold
want "a non-http(s) base URL -> busy, nonzero" busy nonzero
AGENT_POOL_NIGHTCREW_URL="http://user:pw@127.0.0.1:$(cat "$TMP/nc.port")/api" AGENT_POOL_NIGHTCREW_TOKEN_FILE="$TOKEN_FILE" run_hold
want "a base URL carrying credentials -> busy, nonzero" busy nonzero
same "neither bad base URL sent a request" "$(requests)" "0"

for repo in owner owner/repo/extra "owner/.." "own er/repo" ""; do
  REPO_ARG="$repo" hold_with
  want "repo argument '$repo' is rejected -> busy, nonzero" busy nonzero
done
same "no rejected repo argument sent a request" "$(requests)" "0"

OUT="$(AGENT_POOL_NIGHTCREW_URL="$nc_URL" AGENT_POOL_NIGHTCREW_TOKEN_FILE="$TOKEN_FILE" python3 "$SCRIPT" 2>/dev/null)"; RC=$?
same "a usage error prints nothing on stdout" "$OUT" ""
same "a usage error exits 2" "$RC" "2"
hold_with --timeout 0
want "a zero timeout is rejected -> busy, nonzero" busy nonzero
hold_with --timeout soon
want "a non-numeric timeout is a usage error" "" 2

echo
echo "network failures fail closed"
scenario 200 "$CLEAR" '{"delay": 4}'
started=$(date +%s)
hold_with --timeout 1
want "a server slower than the timeout -> busy, nonzero" busy nonzero
same "the timeout is honoured (under 4s)" "$(( $(date +%s) - started < 4 ))" "1"
scenario 200 "$CLEAR" '{"delay": 4}'
started=$(date +%s)
AGENT_POOL_NIGHTCREW_TIMEOUT=1 hold_with
want "AGENT_POOL_NIGHTCREW_TIMEOUT sets the default timeout" busy nonzero
same "the env timeout is honoured (under 4s)" "$(( $(date +%s) - started < 4 ))" "1"

closed_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
AGENT_POOL_NIGHTCREW_URL="http://127.0.0.1:$closed_port/api" AGENT_POOL_NIGHTCREW_TOKEN_FILE="$TOKEN_FILE" run_hold
want "connection refused -> busy, nonzero" busy nonzero

echo
echo "nothing secret is printed"
if grep -qF -- "$SECRET" "$ALL_OUTPUT"; then bad "the token never appears on stdout or stderr" "found in output"
else ok "the token never appears on stdout or stderr"; fi
if grep -qF -- "pw@" "$ALL_OUTPUT"; then bad "URL credentials never appear in output" "found in output"
else ok "URL credentials never appear in output"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
