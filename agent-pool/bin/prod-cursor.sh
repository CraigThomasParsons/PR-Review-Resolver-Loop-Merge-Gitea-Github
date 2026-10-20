#!/usr/bin/env bash
# prod-cursor.sh: the cursor provider's prod (systemd agent-pool-prod@cursor.service).
# One tick per repo that repos.toml enables for cursor, with only the abilities it grants
# there; see prod-common.sh.
set -euo pipefail
AGENT_POOL_PROVIDER=cursor
# shellcheck source=prod-common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/prod-common.sh"
