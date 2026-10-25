# Agent pool commit signing key

Workers in the agent pool never stage, commit or push. After a `resolve` worker exits, the
controller (`agent-pool/bin/prod-common.sh`, `controller_commit()`) builds one commit from the
worktree's changes, signs it with `git commit-tree -S` and `gpg.format=ssh`, gates it and pushes
it (design: `docs/plans/controller-commits-everything.md`). Every such commit carries the
`Agent-Pool-Provider`, `Agent-Pool-Ability`, `Agent-Pool-Worker`, `Agent-Pool-Attempt` and
`Agent-Pool-Model` trailers.

Signing is required and there is no unsigned mode. If `AGENT_POOL_SIGNING_KEY` is unset, is not
an absolute path, is missing or unreadable, has a passphrase, or can be read by other users, the
tick logs `SETUP FAULT [signing]`, writes `faults/signing.json`, exits 2 and claims no resolve
job. Reviews still run, because they never commit. If the key disappears between the claim and
the commit, nothing is committed or pushed and the job goes back to `agent:ready`. The check
runs again on every tick, so a fixed key is picked up on the next tick with nothing to clear.

## The key

- Use a dedicated ed25519 key for this one purpose, made on the controller host. It is not an
  authentication key: never put it in `~/.ssh/authorized_keys` anywhere, never `ssh-add` it to
  an agent, and never reuse an existing key.
- It has no passphrase, because the controller signs headless. The controller runs git with a
  scrubbed environment (`env -i`, so there is no `SSH_AUTH_SOCK`), and `ssh-keygen` reads only
  the key file.
- Mode 0600 in a 0700 directory, owned by the user the pool's systemd units run as.
- Keep it under `~/.ssh/`. The claude, cursor and grok workers' rules deny every read under
  `~/.ssh`. `agent-pool/scripts/policy.py` also denies the configured `AGENT_POOL_SIGNING_KEY`
  path wherever it lives, and the gate sandbox mounts a tmpfs over `/home`.
- Residual risk: codex (`--sandbox workspace-write` does not stop reads) and agy run with
  `AGY_AUTO_APPROVE=1` have no rule list and run as the same user, so they could read the key.
  This is the same exposure as the Gitea token. Only enable them for resolve on repositories you
  trust.
- Never commit it, paste it, or put its contents in an environment variable; only its path goes
  in the config. The controller never prints key material. The readiness check discards
  `ssh-keygen`'s output, and the pool log names only the path. AGENTS.md's pre-commit grep
  (`id_rsa`, `.pem`, ...) and the controller's own refusal of credential-named files are
  backstops, not permission.

## Setup

1. Generate the key (as the pool's user, on the controller host):

   ```bash
   install -d -m 700 ~/.ssh
   ssh-keygen -t ed25519 -N '' -C "agent-pool commit signing $(hostname -s) $(date +%Y-%m)" \
     -f ~/.ssh/agent-pool-commit-signing
   chmod 600 ~/.ssh/agent-pool-commit-signing
   ```

2. Point the pool at it in `~/.config/agent-pool/env`, the `EnvironmentFile` of
   `agent-pool-prod@.service`. systemd expands neither `~` nor `%h` there, so write the full path:

   ```ini
   AGENT_POOL_SIGNING_KEY=/home/<user>/.ssh/agent-pool-commit-signing
   AGENT_POOL_GIT_NAME=agent-pool
   AGENT_POOL_GIT_EMAIL=<the pool bot account's verified email on Gitea>
   ```

   The name and email become the author and committer of every controller commit. The defaults
   are `agent-pool` and `agent-pool@localhost`. Gitea only shows a commit as verified when the
   committer email matches a verified email of the account that holds the public key.

3. Register the public key, `~/.ssh/agent-pool-commit-signing.pub`, on the pool's Gitea bot
   account (Settings, SSH / GPG Keys, Add Key), then use Gitea's Verify button. It asks for a
   signature over a token, made with
   `echo -n '<token>' | ssh-keygen -Y sign -n gitea -f ~/.ssh/agent-pool-commit-signing`.

4. Optional, for local verification, keep an allowed-signers file next to the env file and pass
   it per command (no global git config change is needed):

   ```bash
   printf '%s namespaces="git" %s\n' "<AGENT_POOL_GIT_EMAIL>" \
     "$(cut -d' ' -f1,2 ~/.ssh/agent-pool-commit-signing.pub)" >> ~/.config/agent-pool/allowed_signers
   git -c gpg.ssh.allowedSignersFile="$HOME/.config/agent-pool/allowed_signers" log -1 --show-signature <commit>
   ```

5. Check it before the next tick. This prints `usable` or `unusable` and nothing else:

   ```bash
   ssh-keygen -y -P '' -f /home/<user>/.ssh/agent-pool-commit-signing >/dev/null 2>&1 && echo usable || echo unusable
   ```

   The next tick's log should show no `SETUP FAULT [signing]`. After the first resolve, the
   pushed commit shows `G` for `git log -1 --format=%G?` (with the allowed-signers file above)
   and Verified on Gitea.

## Rotation

Rotate on a schedule (yearly, say), when the host or its user changes, and at once if the key
may have been exposed.

1. Generate the new key beside the old one under a dated name, as in Setup step 1, for example
   `~/.ssh/agent-pool-commit-signing-2027`.
2. Add the new public key to the Gitea bot account and verify it (Setup step 3). Add it to the
   allowed-signers file (Setup step 4). Keep the old key registered for now.
3. Change `AGENT_POOL_SIGNING_KEY` in `~/.config/agent-pool/env` to the new path. Each tick reads
   the env file when it starts, so the next tick signs with the new key. A tick already running
   keeps the old path until it ends, so leave the old private key file in place for at least
   `AGENT_POOL_DEADLINE_SECS` (45 minutes by default), or stop the timers
   (`systemctl --user stop 'agent-pool-prod@*.timer'`) until no tick is running.
4. Confirm the first resolve commit after the switch verifies with the new key:
   `git -c gpg.ssh.allowedSignersFile=... log -1 --format='%G? %GF' <commit>` shows `G` and the
   new key's fingerprint (`ssh-keygen -lf <new>.pub`).
5. Retire the old key:
   - Delete the old private key file: `shred -u ~/.ssh/agent-pool-commit-signing`, plus `rm` of
     its `.pub` once it has been recorded below.
   - In the allowed-signers file, give the old key's line `valid-before="YYYYMMDD"` (the
     switch date). Commits it signed before then still verify, and anything it signs later
     will not.
   - On Gitea, keeping the old public key on the bot account keeps its earlier commits
     Verified. Removing it turns them Unverified, which you want only after a compromise.

If the key may have been exposed, do steps 1 to 4 at once with the timers stopped. Then remove
the old public key from Gitea, and set the old allowed-signers line's `valid-before` to the
earliest possible exposure date (or delete the line). Next, list what the old key signed after
that date, for example
`git log --all --since=<date> --format='%H %G? %GF %ci %s'` filtered on the old fingerprint,
and review those commits by hand. Finally, delete the old private key.
