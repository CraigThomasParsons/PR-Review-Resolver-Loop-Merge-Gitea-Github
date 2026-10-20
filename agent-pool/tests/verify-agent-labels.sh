#!/usr/bin/env bash
# Offline cases for agent-pool/scripts/agent-labels.py.
#
# Gitea is a fake API server on 127.0.0.1 keeping each repo's labels in a JSON file; tea is a
# stub that adds the label to that file (or fails, on request) and logs its arguments. HOME is a
# temp directory. Nothing reaches a real Gitea.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
LABELS_PY="$ROOT/agent-pool/scripts/agent-labels.py"
TMP="$(mktemp -d)"
export HOME="$TMP/home"
mkdir -p "$HOME"
export FAKE_STATE="$TMP/gitea.json" TEA_CALLS="$TMP/tea-calls"
export GITEA_TOKEN="test-token" TEA_BIN="$TMP/tea" TEA_LOGIN="test-login"

cat > "$TMP/fake-gitea.py" <<'PY'
import json, os, re, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
STATE = os.environ["FAKE_STATE"]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(url.query)
        m = re.fullmatch(r"/api/v1/repos/([^/]+/[^/]+)/labels", url.path)
        st = json.load(open(STATE))
        if self.headers.get("Authorization") != "token test-token":
            return self.reply(401, {"message": "bad token"})
        if os.path.exists(STATE + ".fail-read"):
            return self.reply(500, {"message": "boom"})
        if not m or m.group(1) not in st:
            return self.reply(404, {"message": "not found"})
        limit, page = int(q["limit"][0]), int(q["page"][0])
        open(STATE + ".pages", "a").write(f"{m.group(1)} {page}\n")
        self.reply(200, st[m.group(1)][(page - 1) * limit:page * limit])
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
srv = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
cat > "$TEA_BIN" <<'PY'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
arg = lambda n: a[a.index(n) + 1]
open(os.environ["TEA_CALLS"], "a").write(" ".join(a) + "\n")
state = os.environ["FAKE_STATE"]
if os.path.exists(state + ".fail-tea"):
    sys.exit("tea: 422 label already exists or whatever")
if os.path.exists(state + ".tea-lies"):
    sys.exit(0)
st = json.load(open(state))
st[arg("--repo")].append({"name": arg("--name"), "color": arg("--color").lstrip("#"),
                          "description": arg("--description")})
json.dump(st, open(state, "w"))
PY
chmod +x "$TEA_BIN"

echo '{}' > "$FAKE_STATE"
python3 "$TMP/fake-gitea.py" "$TMP/port" &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
export GITEA_BASE_URL="http://127.0.0.1:$(cat "$TMP/port")"

pass=0 fail=0
expect() { # name got wanted-substring
  if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         wanted *%s*\n         got %s\n' "$1" "$3" "$2"
    sed 's/^/           | /' "$TMP/err" | tail -6; fi
}
expect_not() { # name got unwanted-substring
  if [[ "$2" != *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         did not want *%s*\n         got %s\n' "$1" "$3" "$2"; fi
}
repo_state() { # repo labels-json
  python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); s[sys.argv[2]]=json.loads(sys.argv[3]); json.dump(s, open(sys.argv[1],"w"))' \
    "$FAKE_STATE" "$1" "$2"
}
names() { python3 -c 'import json,sys; print(",".join(sorted(l["name"] for l in json.load(open(sys.argv[1]))[sys.argv[2]])))' "$FAKE_STATE" "$1"; }
count() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))[sys.argv[2]]))' "$FAKE_STATE" "$1"; }
run() { rm -f "$TEA_CALLS"; python3 "$LABELS_PY" "$@" > "$TMP/out" 2> "$TMP/err"; RC=$?; }
tea_calls() { cat "$TEA_CALLS" 2>/dev/null || echo none; }
ALL="agent:claimed,agent:done,agent:needs-human,agent:ready"

echo "a repo with none of the labels"
repo_state o/r '[{"name": "bug", "color": "ee0701", "description": ""}]'
run --repo o/r --dry-run
expect "--dry-run exits 0" "$RC" "0"
expect "it lists what it would create" "$(grep -c 'would create' "$TMP/out")" "4"
expect "and says nothing was created" "$(cat "$TMP/out")" "4 of 4 agent:* label(s) missing; dry run"
expect "without calling tea" "$(tea_calls)" "none"
expect "or changing the repo" "$(names o/r)" "bug"
run --repo o/r
expect "a real run exits 0" "$RC" "0"
expect "it creates the four agent:* labels" "$(names o/r)" "$ALL,bug"
expect "through tea, one call each" "$(tea_calls | wc -l)" "4"
expect "with the repo and login" "$(tea_calls)" "labels create --repo o/r --login test-login --name agent:ready --color #1f77b4"
expect "and gitea-labels.py's description" "$(tea_calls)" "--description Queued for the agent pool to claim"
expect "needs-human in red" "$(tea_calls)" "--name agent:needs-human --color #b10026"
expect "it confirms all four are present" "$(cat "$TMP/out")" "created 4, all 4 agent:* labels present"
expect_not "it never creates a review:* label" "$(tea_calls)" "review:"
expect_not "nor night-crew: approved" "$(tea_calls)" "night-crew"
expect_not "nor ready-for-agent" "$(tea_calls)" "ready-for-agent"
expect "the set is exactly gitea-labels.py's agent:* entries" \
  "$(python3 - "$ROOT/skills/pr-loops-common/gitea-labels.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("g", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m); print(",".join(sorted(n for n in m.LABELS if n.startswith("agent:"))))
PY
)" "$ALL"

echo
echo "idempotent"
run --repo o/r
expect "a second run exits 0" "$RC" "0"
expect "it creates nothing" "$(tea_calls)" "none"
expect "and says all are present" "$(cat "$TMP/out")" "all 4 agent:* labels present"
expect "the repo is unchanged" "$(count o/r)" "5"
repo_state o/half '[{"name": "agent:ready", "color": "1f77b4", "description": "Queued for the agent pool to claim"},
                    {"name": "agent:done", "color": "#000000", "description": "ours"}]'
run --repo o/half
expect "a half-labelled repo gets only what it lacks" "$(tea_calls | grep -o -- '--name [^ ]*' | tr '\n' ' ')" \
  "--name agent:claimed --name agent:needs-human "
expect "a label with another colour is reported" "$(cat "$TMP/out")" "agent:done (colour or description differs"
expect "but left as it is" "$(python3 -c 'import json,sys; print([l["color"] for l in json.load(open(sys.argv[1]))["o/half"] if l["name"]=="agent:done"])' "$FAKE_STATE")" "#000000"
expect "and not duplicated" "$(count o/half)" "4"

echo
echo "every page is read"
python3 - "$FAKE_STATE" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
st["o/big"] = [{"name": f"area:{i:03d}", "color": "cccccc", "description": ""} for i in range(120)]
st["o/big"].append({"name": "agent:ready", "color": "1f77b4", "description": "Queued for the agent pool to claim"})
json.dump(st, open(sys.argv[1], "w"))
PY
rm -f "$FAKE_STATE.pages"
run --repo o/big
expect "a label on page 3 counts as present" "$(tea_calls | grep -c -- '--name agent:ready')" "0"
expect "so only the other three are created" "$(tea_calls | wc -l)" "3"
expect "it read pages 1 to 3" "$(grep -c '^o/big ' "$FAKE_STATE.pages")" "6"

echo
echo "it fails closed"
touch "$FAKE_STATE.fail-read"
run --repo o/r
expect "an unreadable label list exits 3" "$RC" "3"
expect "and says nothing was created" "$(cat "$TMP/err")" "HTTP 500 reading the labels of o/r; nothing created"
expect "without calling tea" "$(tea_calls)" "none"
rm -f "$FAKE_STATE.fail-read"
run --repo o/missing
expect "an unknown repo exits 3" "$RC" "3"
expect "naming the likely cause" "$(cat "$TMP/err")" "no such repo, or no access"
GITEA_BASE_URL="http://127.0.0.1:1" run --repo o/r
expect "an unreachable Gitea exits 3" "$RC" "3"
GITEA_TOKEN="" run --repo o/r
expect "no token exits 3" "$RC" "3"
expect "and says so" "$(cat "$TMP/err")" "no token"
expect "none of these called tea" "$(tea_calls)" "none"
repo_state o/new '[]'
touch "$FAKE_STATE.fail-tea"
run --repo o/new
expect "a failing tea exits 1" "$RC" "1"
expect "and reports each failure" "$(grep -c FAILED "$TMP/err")" "4"
rm -f "$FAKE_STATE.fail-tea"
touch "$FAKE_STATE.tea-lies"
run --repo o/new
expect "a create that tea claims but Gitea lacks exits 1" "$RC" "1"
expect "naming what is missing" "$(cat "$TMP/err")" "still missing agent:ready"
rm -f "$FAKE_STATE.tea-lies"
run --repo o/new
expect "the next run completes it" "$(names o/new)" "$ALL"

echo
echo "arguments"
run
expect "no --repo is refused (exit 2)" "$RC" "2"
for bad in "noslash" "o/r/x" "o/r;rm" "../x" "o/.." "o/r?page=2"; do
  run --repo "$bad"
  expect "--repo '$bad' is refused (exit 2)" "$RC" "2"
done
expect "none of these called tea" "$(tea_calls)" "none"
expect "nothing was written under HOME" "$(find "$HOME" -mindepth 1 | wc -l)" "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
