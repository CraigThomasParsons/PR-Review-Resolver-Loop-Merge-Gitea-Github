#!/usr/bin/env bash
# Offline cases for the agent pool's systemd user units (systemd/agent-pool-*) and their
# installer (agent-pool/bin/install-systemd-units.sh).
#
# HOME is a temp directory and every install goes to a temp --dest; a stub systemctl on PATH
# records any call, and none may happen. systemd-analyze verify runs when it is available.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$ROOT/agent-pool/bin/install-systemd-units.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
unset XDG_CONFIG_HOME
mkdir -p "$HOME/bin"
cat > "$HOME/bin/systemctl" <<'SH'
#!/usr/bin/env bash
echo "systemctl $*" >> "$HOME/systemctl-calls"
exit 0
SH
chmod +x "$HOME/bin/systemctl"
export PATH="$HOME/bin:$PATH"

PROVIDERS=(claude codex cursor grok agy)
pass=0 fail=0
expect() { # name got wanted-substring
  if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         wanted *%s*\n         got %s\n' "$1" "$3" "$2"; fi
}
expect_not() { # name got unwanted-substring
  if [[ "$2" != *"$3"* ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n         did not want *%s*\n         got %s\n' "$1" "$3" "$2"; fi
}
install_units() { bash "$INSTALL" "$@" > "$TMP/out" 2> "$TMP/err"; RC=$?; }
tree() { (cd "$1" 2>/dev/null && find . -type f | LC_ALL=C sort) || echo "(no dir)"; }
stamp() { (cd "$1" && find . -type f -printf '%p %T@ %s\n' | LC_ALL=C sort); }
key() { grep -E "^$2=" "$1" | tail -1 | cut -d= -f2-; }
minute() { key "$D/agent-pool-prod@$1.timer.d/stagger.conf" OnCalendar | sed -E 's/.*:([0-9]{2}):00$/\1/'; }

echo "the installer copies the units and generates the staggers"
D="$TMP/units"
install_units --dest "$D"
expect "it exits 0" "$RC" "0"
expect "it installs the four units and five stagger drop-ins" "$(tree "$D" | tr '\n' ' ')" \
  "./agent-pool-doctor.service ./agent-pool-doctor.timer ./agent-pool-prod@.service ./agent-pool-prod@.timer ./agent-pool-prod@agy.timer.d/stagger.conf ./agent-pool-prod@claude.timer.d/stagger.conf ./agent-pool-prod@codex.timer.d/stagger.conf ./agent-pool-prod@cursor.timer.d/stagger.conf ./agent-pool-prod@grok.timer.d/stagger.conf "
expect "and nothing else" "$(tree "$D" | wc -l)" "9"
expect_not "no @POOL_ROOT@ is left" "$(cat "$D"/*.service "$D"/*.timer)" "@POOL_ROOT@"
expect "the prod service runs the instance's entrypoint from the deployed copy" \
  "$(key "$D/agent-pool-prod@.service" ExecStart)" "%h/.local/share/agent-pool/agent-pool/bin/prod-%i.sh"
expect "the doctor service runs doctor.sh from it" \
  "$(key "$D/agent-pool-doctor.service" ExecStart)" "%h/.local/share/agent-pool/agent-pool/bin/doctor.sh"
expect "the files are world-readable, not executable" "$(stat -c %a "$D/agent-pool-prod@.service")" "644"
expect "it enables nothing" "$(cat "$HOME/systemctl-calls" 2>/dev/null || echo none)" "none"
expect "but says how" "$(cat "$TMP/out")" "systemctl --user enable --now agent-pool-prod@agy.timer"
expect "and warns that the pool root is not deployed yet" "$(cat "$TMP/err")" "is not there yet"
expect "nothing went to the real unit dir" "$(tree "$HOME/.config/systemd/user")" "(no dir)"

echo
echo "idempotent, and it deletes nothing"
before="$(stamp "$D")"
install_units --dest "$D"
expect "a second run exits 0" "$RC" "0"
expect "and changes nothing" "$(tail -n 8 "$TMP/out" | head -1)" "0 file(s) changed"
expect "every file is reported unchanged" "$(grep -c '^unchanged' "$TMP/out")" "9"
expect "no file was rewritten" "$(stamp "$D")" "$before"
echo "# a local note" > "$D/agent-pool-local.conf"
echo "OnCalendar=*:00" >> "$D/agent-pool-prod@grok.timer.d/stagger.conf"
install_units --dest "$D"
expect "a hand-edited file is put back" "$(grep -c 'OnCalendar=\*:00' "$D/agent-pool-prod@grok.timer.d/stagger.conf")" "0"
expect "and reported" "$(cat "$TMP/out")" "installed  $D/agent-pool-prod@grok.timer.d/stagger.conf"
expect "an unrelated file in the unit dir is left alone" "$(cat "$D/agent-pool-local.conf" 2>/dev/null)" "# a local note"
expect "no temp file is left behind" "$(find "$D" -name '.*' -type f | wc -l)" "0"

echo
echo "--list, --pool-root and the default destination"
install_units --dest "$TMP/listed" --list
expect "--list exits 0" "$RC" "0"
expect "it says what it would add" "$(grep -c '^would add' "$TMP/out")" "9"
expect "and writes nothing" "$(tree "$TMP/listed")" "(no dir)"
install_units --dest "$TMP/rooted" --pool-root "$ROOT/"
expect "--pool-root goes into ExecStart, trailing slash dropped" \
  "$(key "$TMP/rooted/agent-pool-prod@.service" ExecStart)" "$ROOT/agent-pool/bin/prod-%i.sh"
expect "with no warning when the scripts are there" "$([ -s "$TMP/err" ] && cat "$TMP/err" || echo quiet)" "quiet"
install_units
expect "with no --dest it installs into ~/.config/systemd/user" "$(tree "$HOME/.config/systemd/user" | wc -l)" "9"
XDG_CONFIG_HOME="$TMP/xdg" bash "$INSTALL" > /dev/null 2>&1
expect "or \$XDG_CONFIG_HOME/systemd/user" "$(tree "$TMP/xdg/systemd/user" | wc -l)" "9"
for bad in "relative/path" "/opt/a&b" "/opt/a|b" "/opt/a b" "%h" "/" "/opt/%n"; do
  install_units --dest "$TMP/bad" --pool-root "$bad"
  expect "--pool-root '$bad' is refused (exit 2)" "$RC" "2"
done
install_units --dest "$TMP/bad" --enable
expect "an unknown argument is refused (exit 2)" "$RC" "2"
install_units --dest
expect "--dest with no value is refused (exit 2)" "$RC" "2"
expect "a refused install writes nothing" "$(tree "$TMP/bad")" "(no dir)"
expect "and no run ever called systemctl" "$(cat "$HOME/systemctl-calls" 2>/dev/null || echo none)" "none"

echo
echo "the schedule"
minutes=""
for p in "${PROVIDERS[@]}"; do
  m="$(minute "$p")"
  minutes+="$m "
  expect "agent-pool-prod@$p has an entrypoint" "$(ls "$ROOT/agent-pool/bin/prod-$p.sh" 2>&1)" "prod-$p.sh"
  expect "its stagger resets the template's OnCalendar first" "$(grep -c '^OnCalendar=$' "$D/agent-pool-prod@$p.timer.d/stagger.conf")" "1"
  clash=""
  for off in 0 1 2; do
    case "$(printf '%02d' $(( (10#$m + off) % 60 )))" in 08|23|38|53|37) clash="$m+$off" ;; esac
  done
  expect "$p ticks at :$m, clear of the merge tick and the pipeline" "${clash:-clear}" "clear"
done
expect "every provider has its own minute" "$(tr ' ' '\n' <<< "$minutes" | grep -v '^$' | sort | uniq -d | wc -l)" "0"
expect "the random delay stays inside the gap" "$(key "$D/agent-pool-prod@.timer" RandomizedDelaySec)" "120"
expect "and is fixed per instance" "$(key "$D/agent-pool-prod@.timer" FixedRandomDelay)" "true"
expect "missed ticks run after a suspend" "$(key "$D/agent-pool-prod@.timer" Persistent)" "true"
expect "the doctor runs every 15 minutes off the merge tick" "$(key "$D/agent-pool-doctor.timer" OnCalendar)" "*:02/15"
for unit in agent-pool-prod@.service agent-pool-doctor.service; do
  expect "$unit is a oneshot" "$(key "$D/$unit" Type)" "oneshot"
  expect "$unit's env file is optional" "$(key "$D/$unit" EnvironmentFile)" "-%h/.config/agent-pool/env"
  expect "$unit sets an explicit PATH" "$(key "$D/$unit" Environment)" "PATH=/usr/local/bin:/usr/bin:/bin:%h/.local/bin"
done
expect_not "no unit starts anything by itself" "$(cat "$D"/agent-pool-*.service "$D"/agent-pool-*.timer)" "systemctl"

echo
echo "systemd-analyze verify"
if command -v systemd-analyze > /dev/null 2>&1; then
  V="$TMP/verify"
  bash "$INSTALL" --dest "$V" --pool-root "$ROOT" > /dev/null 2>&1
  cp "$V/agent-pool-prod@.service" "$V/agent-pool-prod@claude.service"
  cp "$V/agent-pool-prod@.timer" "$V/agent-pool-prod@claude.timer"
  out="$(SYSTEMD_UNIT_PATH="$V:" systemd-analyze --user verify --man=no \
    "$V/agent-pool-prod@claude.timer" "$V/agent-pool-prod@claude.service" \
    "$V/agent-pool-doctor.timer" "$V/agent-pool-doctor.service" 2>&1)"
  rc=$?
  ours="$(grep -E 'agent-pool' <<< "$out" || true)"
  if [ "$rc" -ne 0 ] && grep -qiE 'connect|bus|no such file or directory.*(runtime|bus)' <<< "$out" && [ -z "$ours" ]; then
    echo "  skip  systemd-analyze could not reach a user manager here: $(head -1 <<< "$out")"
  else
    expect "systemd-analyze verify accepts the units" "$rc" "0"
    expect "and says nothing about them" "${ours:-quiet}" "quiet"
  fi
  for spec in "*-*-* *:05:00" "*:02/15"; do
    expect "'$spec' is a valid calendar spec" "$(systemd-analyze calendar "$spec" 2>&1)" "Next elapse"
  done
else
  echo "  skip  systemd-analyze is not installed"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
