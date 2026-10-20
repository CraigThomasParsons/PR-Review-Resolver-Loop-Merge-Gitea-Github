#!/usr/bin/env bash
# prod-claude.sh: the claude provider's prod (systemd agent-pool-prod@claude.service).
# One tick per repo that repos.toml enables for claude, with only the abilities it grants
# there; see prod-common.sh.
set -euo pipefail
AGENT_POOL_PROVIDER=claude
# shellcheck source=prod-common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/prod-common.sh"
