# Test recipes. The agent pool's gate sandbox runs the gated ones from .agent-pool/gates.toml:
# no network, read-only toolchains, HOME on an empty tmpfs, and a plain checkout with no .git.
# They run the same way from a normal checkout (`just test`).

set shell := ["bash", "-euo", "pipefail", "-c"]

default: test

# Every gated suite.
test: pool-core pool-lease pool-providers pool-gates loops night-shift

# Agent-pool labels, doctor, nightcrew hold and systemd units (fast; also the catch-all gate).
pool-core:
    bash agent-pool/tests/verify-agent-labels.sh
    bash agent-pool/tests/verify-doctor.sh
    bash agent-pool/tests/verify-nightcrew-issue-hold.sh
    bash agent-pool/tests/verify-systemd-units.sh

pool-lease:
    bash agent-pool/tests/verify-lease.sh

pool-providers:
    bash agent-pool/tests/verify-providers.sh

pool-gates:
    bash agent-pool/tests/verify-gates.sh

# The shared PR-loop scripts (skills/pr-loops-common).
loops:
    bash skills/pr-loops-common/tests/verify-trigger.sh
    bash skills/pr-loops-common/tests/verify-merge.sh
    bash skills/pr-loops-common/tests/verify-resolve.sh
    bash skills/pr-loops-common/tests/verify-fallback.sh
    bash skills/pr-loops-common/tests/verify-composer.sh
    python3 skills/pr-loops-common/tests/test_label_new_pr.py

night-shift:
    bash scripts/tools/tests/verify-night-shift.sh

# Not gated: needs Behave (requirements-conduits.lock), which the sandbox's python3 lacks.
pool-conduits:
    bash agent-pool/tests/verify-conduits.sh

# Not gated: copies the tree with `git ls-files`, and a gate checkout has no .git.
install:
    bash tests/verify-install.sh
