#!/usr/bin/env bash
# prod-codex.sh: the codex provider's prod (systemd agent-pool-prod@codex.service).
# One tick per repo that repos.toml enables for codex, with only the abilities it grants
# there; see prod-common.sh.
set -euo pipefail
AGENT_POOL_PROVIDER=codex
# shellcheck source=prod-common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/prod-common.sh"
