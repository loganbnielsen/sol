---
id: REFAC-026
type: refactor
severity: medium
source: codebase simplification review 2026-06-15
branch: REFAC-026/shared-wait-port-helper
worktree: /home/lbendtly/Code/sun-REFAC-026-shared-wait-port-helper
---

Extract port-wait loop repeated across 6 ensure-*.sh scripts into a shared helper

**Depends on:** None.

**Description:**

Every `ensure-*.sh` script in `platform/local/scripts/` contains its own copy of the same `nc -z` polling loop. At least six scripts have this pattern:

| Script | Lines | Port var | Iterations |
|--------|-------|----------|-----------|
| `ensure-broker.sh` | 16–22 | `KAFKA_PORT` | 20 |
| `ensure-postgres.sh` | 24–30 | `PORT` | 30 (×2) |
| `ensure-loki.sh` | 20–26 | (hardcoded) | 30 |
| `ensure-grafana.sh` | 52–58 | (hardcoded) | 30 |
| `ensure-prometheus.sh` | 39–45 | (hardcoded) | 30 |
| `ensure-pushgateway.sh` | 28–34 | (hardcoded) | 20 |
| `start-redpanda.sh` | 43–49 | (hardcoded) | 30 |

Each copy has its own delay constant, iteration count, and slightly different error message. A bug in one copy (e.g., missing error exit, wrong sleep duration) won't be fixed in the others.

**Remediation:**

1. Create `platform/local/scripts/lib/wait-port.sh`:
   ```bash
   #!/usr/bin/env bash
   # wait_for_port PORT [MAX_ATTEMPTS] [SLEEP_SECS]
   # Exits 0 when the port accepts connections; exits 1 on timeout.
   wait_for_port() {
     local port=$1 max=${2:-30} delay=${3:-1}
     for i in $(seq 1 "$max"); do
       nc -z localhost "$port" 2>/dev/null && return 0
       sleep "$delay"
     done
     echo "error: port $port not ready after $((max * delay))s" >&2
     return 1
   }
   ```

2. In each `ensure-*.sh`, replace the inline loop with:
   ```bash
   source "$(dirname "$0")/lib/wait-port.sh"
   wait_for_port "$PORT" 30 1 || exit 1
   ```

**Acceptance criteria:**

- `grep -rn "seq 1.*nc -z\|for i in.*nc -z" platform/local/scripts/` returns zero hits in the top-level script files.
- All ensure scripts still wait correctly and exit non-zero on timeout.
- `bash -n` passes on all modified scripts (syntax check).
