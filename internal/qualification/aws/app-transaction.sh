#!/usr/bin/env bash
set -uo pipefail

LOG_DIR="${1:?usage: app-transaction.sh LOG_DIR}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TRANSACTION="$(cd "$HERE/.." && pwd)/transaction.py"
NS=pluto-payments
WORKER_NS=pluto-comms
JOB="row-transaction-$(date -u +%H%M%S)"
URL="http://charge-svc.$NS.svc.cluster.local"

kubectl -n "$NS" get pods -o wide >"$LOG_DIR/app-pods.txt" 2>&1 || exit 1
kubectl -n "$WORKER_NS" get pods -o wide >"$LOG_DIR/app-worker-pods.txt" 2>&1 || true
kubectl -n "$NS" logs -l app.kubernetes.io/component=svc --tail=80 --all-containers=true \
  >"$LOG_DIR/app-charge-svc.log" 2>&1 || true
kubectl -n "$WORKER_NS" logs -l app.kubernetes.io/component=worker --tail=80 --all-containers=true \
  >"$LOG_DIR/app-notify-worker.log" 2>&1 || true

cleanup() { kubectl -n "$NS" delete job "$JOB" --ignore-not-found >"$LOG_DIR/app-transaction-cleanup.txt" 2>&1 || true; }
trap cleanup EXIT

# The Job only drives the HTTP exchange and prints each response with a stable
# prefix. It never decides success: an empty or malformed response would
# otherwise be read as the worker's effect. The host owns the verdict below with
# the same structural predicate the transport path uses.
kubectl -n "$NS" apply -f - >"$LOG_DIR/app-transaction-job.txt" 2>&1 <<EOF || exit 1
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: transaction
          image: curlimages/curl:8.10.1
          command: ["sh", "-c"]
          args:
            - |
              set -e
              health=\$(curl -fsS -m 10 $URL/healthz)
              printf 'SOL_TRANSACTION health %s\n' "\$health"
              charge=\$(curl -fsS -m 30 -X POST $URL/charges -H 'Content-Type: application/json' -d '{"customer_id":"cus_qualification","amount_cents":4999,"currency":"usd"}')
              printf 'SOL_TRANSACTION charge %s\n' "\$charge"
              i=0
              while [ \$i -lt 12 ]; do
                i=\$((i + 1))
                notifications=\$(curl -fsS -m 20 $URL/notifications 2>&1 || true)
                printf 'SOL_TRANSACTION notifications %s\n' "\$notifications"
                sleep 5
              done
EOF

complete=1
if ! kubectl -n "$NS" wait --for=condition=complete "job/$JOB" --timeout=240s \
  >"$LOG_DIR/app-transaction-wait.txt" 2>&1; then
  complete=0
  kubectl -n "$NS" wait --for=condition=failed "job/$JOB" --timeout=10s \
    >>"$LOG_DIR/app-transaction-wait.txt" 2>&1 || true
fi

pod="$(kubectl -n "$NS" get pods -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -n "$pod" ]; then
  kubectl -n "$NS" logs "$pod" >"$LOG_DIR/app-transaction.txt" 2>&1 || true
fi

# Structural verdict: the operation response must carry a nonempty id and a
# read-back must contain that exact id. The Job log is transport evidence, not
# the decision.
verdict_err="$LOG_DIR/app-transaction-verdict.err"
: >"$verdict_err"
charge_payload="$(sed -n 's/^SOL_TRANSACTION charge //p' "$LOG_DIR/app-transaction.txt" 2>/dev/null | tail -1)"
if [ -z "$charge_payload" ]; then
  echo "the transaction job produced no charge response (complete=$complete)" >&2
  tail -20 "$LOG_DIR/app-transaction.txt" 2>/dev/null >&2
  exit 1
fi
if ! charge_id="$(printf '%s' "$charge_payload" | python3 "$TRANSACTION" charge-id 2>>"$verdict_err")"; then
  echo "the charge response did not carry a usable id:" >&2
  cat "$verdict_err" >&2
  tail -20 "$LOG_DIR/app-transaction.txt" 2>/dev/null >&2
  exit 1
fi
printf 'charge id: %s\n' "$charge_id" >>"$LOG_DIR/app-transaction.txt"

visible=0
while IFS= read -r readback; do
  [ -n "$readback" ] || continue
  if printf '%s' "$readback" | python3 "$TRANSACTION" charge-effect "$charge_id" 2>>"$verdict_err"; then
    visible=1
    break
  fi
done <<EOF
$(sed -n 's/^SOL_TRANSACTION notifications //p' "$LOG_DIR/app-transaction.txt" 2>/dev/null)
EOF

if [ "$visible" = 0 ]; then
  echo "the transaction did not complete: no read-back carried the worker's charge $charge_id" >&2
  cat "$verdict_err" 2>/dev/null >&2
  tail -20 "$LOG_DIR/app-transaction.txt" 2>/dev/null >&2
  exit 1
fi
printf 'read-back: the worker effect %s is visible to the service\n' "$charge_id" \
  >>"$LOG_DIR/app-transaction.txt"

kubectl get ingress --all-namespaces -o wide >"$LOG_DIR/app-ingresses.txt" 2>&1 || true
kubectl -n "$NS" get svc >"$LOG_DIR/app-services.txt" 2>&1 || true
exit 0
