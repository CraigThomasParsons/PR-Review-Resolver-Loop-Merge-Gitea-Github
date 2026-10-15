# Runtime adaptation — which agent is running this skill

These skills are shared between Claude Code (`~/.claude/skills`) and Cursor
(`~/.cursor/skills`, a symlink to the same directory). Most of each skill is
runtime-neutral. This file records the parts that are not, so individual skills
can stay short.

## Detect

    ~/.claude/skills/pr-loops-common/detect-agent.sh
    # -> {"agent":"claude","confidence":"high","signal":"CLAUDECODE"}

    ~/.claude/skills/pr-loops-common/detect-agent.sh --probe
    # -> {"available":[{"agent":"claude",...},{"agent":"codex",...},...]}

`CLAUDECODE` is verified. Cursor and Codex markers are inferred from
vendor-shipped code and are **not yet confirmed from inside those runtimes** —
run the script there once with `--learn` to pin them down.

Note it deliberately does NOT treat `CODEX_COMPANION_*` as "running as Codex":
those are set by the Claude plugin and mean the opposite.

## What is actually runtime-neutral (do not special-case these)

- Every `~/.claude/skills/.../*.sh|*.py` invocation. Absolute paths to scripts
  on disk; any agent can run them.
- The tracker, gate, worktree and marker mechanics. Plain CLIs and files.
- Reading `.slice-pipeline.toml`, `AGENTS.md`, `CLAUDE.md`.

## What differs

| Concern | Claude Code | Cursor | Elsewhere (codex/grok/gemini) |
|---|---|---|---|
| Sibling skill (`/slice-dispatch`) | `Skill` tool | slash command (`modelSlashCommands`) | none — inline the steps or shell out |
| Asking the user | `AskUserQuestion` | Cursor's own prompt | never ask; these run unattended |
| Background work | `Agent` tool / tmux | tmux | tmux only |
| Auto-loaded repo rules | `CLAUDE.md` | `AGENTS.md` | neither; pass explicitly |

## Spawning workers

`tmux-pipeline` spawns workers by name. It has historically hardcoded `claude`.
When a crew coach is in play, the worker command should come from the coach's
routing decision rather than being baked in, so a rate-limited vendor can be
swapped without editing the skill. Until then, `claude` remains the default.

## Rule

Detect once, near the top of a run, and record the answer in the run directory.
Do not re-detect per step, and do not branch on runtime for anything in the
"runtime-neutral" list above — that is how these skills rot.
