#!/usr/bin/env bash
set -uo pipefail

LOG_DIR="${1:?usage: app-transaction.sh LOG_DIR}"
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
              echo "health: \$(curl -fsS -m 10 $URL/health)"
              charge=\$(curl -fsS -m 30 -X POST $URL/charges -H 'Content-Type: application/json' -d '{"customer_id":"cus_qualification","amount_cents":4999,"currency":"usd"}')
              echo "charge: \$charge"
              id=\$(printf '%s' "\$charge" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
              echo "charge id: \$id"
              i=0
              while [ \$i -lt 12 ]; do
                i=\$((i + 1))
                notifications=\$(curl -fsS -m 20 $URL/notifications || true)
                echo "notifications attempt \$i: \$notifications"
                case "\$notifications" in
                  *"\$id"*) echo "read-back: the worker's row is visible to the service"; exit 0 ;;
                esac
                sleep 5
              done
              echo "the worker never wrote the charge back within 60s"
              exit 1
EOF

if ! kubectl -n "$NS" wait --for=condition=complete "job/$JOB" --timeout=240s \
  >"$LOG_DIR/app-transaction-wait.txt" 2>&1; then
  kubectl -n "$NS" wait --for=condition=failed "job/$JOB" --timeout=10s \
    >>"$LOG_DIR/app-transaction-wait.txt" 2>&1 || true
fi

pod="$(kubectl -n "$NS" get pods -l job-name="$JOB" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -n "$pod" ]; then
  kubectl -n "$NS" logs "$pod" >"$LOG_DIR/app-transaction.txt" 2>&1 || true
fi

if ! grep -qF 'read-back: the worker' "$LOG_DIR/app-transaction.txt" 2>/dev/null; then
  echo "the transaction did not complete: the service never served the worker's row back" >&2
  tail -20 "$LOG_DIR/app-transaction.txt" 2>/dev/null >&2
  exit 1
fi

kubectl get ingress --all-namespaces -o wide >"$LOG_DIR/app-ingresses.txt" 2>&1 || true
kubectl -n "$NS" get svc >"$LOG_DIR/app-services.txt" 2>&1 || true
exit 0
