# Hermes Scrum Master

A local fallback for when Grok Bot is rate limited: it finds the items that need Craig, asks
him about each one in a Slack DM, and relays his exact answer to Gitea for whoever acts on it.
Notion task: [Hermes Scrum Master](https://app.notion.com/p/42137d296f2981968151df7faeb595fa)
(Agent Worker Pool project).

It is deliberately not an LLM. Like `agent-pool/bin/doctor.sh`, it must keep working when
every provider is rate limited, so it is one stdlib-only Python file (`scrum_master.py`,
Python 3.11+), run every 10 minutes by a systemd user timer.

## What one tick does

1. **Relay answers.** For every question still open (asked within `answer_window_days`), it
   reads the Slack thread. The first reply from `craig_user_id` that is a plain human message
   (no `bot_id`, no `subtype`) is posted, word for word, as a Gitea comment on the PR or issue,
   addressed by `[relay.mentions]` (or to the PR author). The comment carries a hidden
   `hermes-scrum-master:relay` marker, and the tick checks for it before posting, so a crash
   between posting and saving never posts twice. Replies from anyone else are ignored.
2. **Watch, read-only.**
   - Gitea: open PRs labelled `agent:needs-human` or `review:needs-human`, across every repo
     the token can see (or just `[gitea].repos`), via `GET /repos/issues/search`.
   - NightCrew: jobs that are `failed`, have `needs_human_at` set, or are
     claimed/running/parked with a lapsed lease or no heartbeat for `stuck_after_minutes`
     (a job parked on a rate limit that has not reset yet is expected and skipped). It reads
     `night_crew_jobs` straight from the SQLite file, opened with `mode=ro` and
     `PRAGMA query_only = ON`. NightCrew's HTTP API is not called: its read routes only show
     one worker's own jobs, and its write routes (`POST /claim-next` above all) are off limits.
3. **Ask.** One DM per item: the decision first, then lettered options (the last is always
   "something else, in your own words"), then the item's **Tailscale** link (LAN URLs are
   rewritten to `[gitea].public_base`). At most `max_new_per_tick` new questions per tick.
4. **De-duplicate.** Each item has a fingerprint: for a PR, its head SHA and its needs-human
   labels; for a NightCrew job, its status, attempt, failure streak and last failure. An
   item is asked about again only when its fingerprint changes, or when it went away and came
   back. Other label churn and new comments do not re-ask.

## What it will never do

- Act on an answer, its own or Craig's. It only relays.
- Write to Gitea except `POST /repos/{owner}/{repo}/issues/{n}/comments`. The client refuses
  every other write, so it cannot merge, push, relabel or close anything.
- Write to the NightCrew DB, or call any NightCrew endpoint.
- Count anything but Craig's own Slack messages as an answer.
- Log or store a token. Tokens are read from files (or the environment) and sent only as
  request headers.

## Hand-back

Every question, relay and resolved item is appended to
`~/.local/state/hermes-scrum-master/qa-log.jsonl`. When Grok Bot is back, Projects Manager and
Scrum Master read it with:

```bash
python3 scrum-master/scrum_master.py log --since 2026-11-23T00:00:00Z
```

`state.json` beside it holds the per-item fingerprints and open questions.

## Setup (only once Craig says go)

Nothing in this repo installs, enables or starts it.

1. Create a Slack app with a bot user, scopes `chat:write`, `im:write`, `im:history`;
   install it to the workspace and put the bot token (`xoxb-...`) in
   `~/.config/hermes-scrum-master/slack_bot_token` (`chmod 600`).
2. `mkdir -p ~/.config/hermes-scrum-master` and copy `config/config.example.toml` to
   `~/.config/hermes-scrum-master/config.toml`. Check `craig_user_id`, and set
   `ignore_failed_before` so old NightCrew failures do not all arrive at once.
   The Gitea token defaults to `~/.config/pulse/gitea_token`, the one the PR loops use.
3. Check it, then see what it would ask without sending anything:
   ```bash
   python3 scrum-master/scrum_master.py check
   python3 scrum-master/scrum_master.py tick --dry-run
   ```
4. Install the units by hand:
   ```bash
   sed "s#@HSM_ROOT@#$PWD#" systemd/hermes-scrum-master.service \
     > ~/.config/systemd/user/hermes-scrum-master.service
   cp systemd/hermes-scrum-master.timer ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now hermes-scrum-master.timer
   ```

## Tests

```bash
scrum-master/tests/verify-scrum-master.sh
```

Offline only: a fake Gitea and a fake Slack on localhost and a throwaway NightCrew-shaped
SQLite file. They cover the question shape (decision first, lettered options, Tailscale
link), de-duplication and re-asking on change, the per-tick cap, verbatim relay from Craig's
id only, crash-safe single relay, the comment-only write surface, the read-only NightCrew DB
(byte-identical after a tick, writes refused), dry run, and setup errors.
