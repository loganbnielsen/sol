#!/usr/bin/env bash
set -uo pipefail

LOG_DIR="${1:?usage: app-transaction.sh LOG_DIR}"
NS=pluto-payments
PORT=18080
SVC="charge-svc"

kubectl -n "$NS" get pods -o wide >"$LOG_DIR/app-pods.txt" 2>&1 || exit 1
kubectl -n "$NS" get events --sort-by=.lastTimestamp >"$LOG_DIR/app-events.txt" 2>&1 || true
kubectl -n "$NS" logs -l app.kubernetes.io/component=svc --tail=80 --all-containers=true \
  >"$LOG_DIR/app-charge-svc.log" 2>&1 || true
kubectl -n "$NS" logs -l app.kubernetes.io/component=worker --tail=80 --all-containers=true \
  >"$LOG_DIR/app-notify-worker.log" 2>&1 || true

kubectl -n "$NS" port-forward "svc/$SVC" "$PORT:80" >"$LOG_DIR/app-port-forward.log" 2>&1 &
forwarder=$!
trap 'kill "$forwarder" 2>/dev/null || true' EXIT

attempt=0
until curl -fsS -m 5 "localhost:$PORT/health" >"$LOG_DIR/app-health.txt" 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 12 ]; then
    echo "the service never answered /health over the port-forward" >&2
    exit 1
  fi
  sleep 5
done

{
  printf 'health: %s\n' "$(cat "$LOG_DIR/app-health.txt")"
  printf 'charge: '
  curl -fsS -m 30 -X POST "localhost:$PORT/charges" \
    -H 'Content-Type: application/json' \
    -d '{"customer_id":"cus_qualification","amount_cents":4999,"currency":"usd"}' \
    >"$LOG_DIR/app-charge.txt" 2>&1 && cat "$LOG_DIR/app-charge.txt" || printf 'FAILED\n'
  printf '\n'
} >"$LOG_DIR/app-transaction.txt" 2>&1

charge_id="$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$LOG_DIR/app-charge.txt" 2>/dev/null | head -1)"
attempt=0
until [ -n "$charge_id" ] && grep -qF "$charge_id" "$LOG_DIR/app-notifications.txt" 2>/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 12 ]; then
    echo "the worker never wrote the charge back within 60s: $charge_id absent from /notifications" >&2
    curl -sS -m 20 "localhost:$PORT/notifications" >"$LOG_DIR/app-notifications.txt" 2>&1 || true
    printf 'notifications: %s\n' "$(cat "$LOG_DIR/app-notifications.txt" 2>/dev/null)" \
      >>"$LOG_DIR/app-transaction.txt"
    exit 1
  fi
  sleep 5
  curl -fsS -m 20 "localhost:$PORT/notifications" >"$LOG_DIR/app-notifications.txt" 2>&1 || true
done

{
  printf 'notifications: %s\n' "$(cat "$LOG_DIR/app-notifications.txt")"
  printf 'the worker consumed the charge and wrote it back: %s\n' "$charge_id"
} >>"$LOG_DIR/app-transaction.txt" 2>&1

kubectl get ingress --all-namespaces -o wide >"$LOG_DIR/app-ingresses.txt" 2>&1 || true
kubectl get svc -n "$NS" >"$LOG_DIR/app-services.txt" 2>&1 || true
exit 0
