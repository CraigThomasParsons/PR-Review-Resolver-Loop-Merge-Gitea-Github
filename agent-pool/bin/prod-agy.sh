#!/usr/bin/env bash
# prod-agy.sh: the agy provider's prod (systemd agent-pool-prod@agy.service).
# One tick per repo that repos.toml enables for agy, with only the abilities it grants
# there; see prod-common.sh.
# agy may plan, review, prototype and author tests, never resolve: repoconfig.py caps it,
# and prod-common.sh refuses it a resolve job under an entrypoint whatever AGY_AUTO_APPROVE says.
set -euo pipefail
AGENT_POOL_PROVIDER=agy
# shellcheck source=prod-common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/prod-common.sh"
