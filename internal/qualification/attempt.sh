#!/usr/bin/env bash

attempt_emit() {
  if command -v say >/dev/null 2>&1; then
    say "$1"
    return 0
  fi
  printf '%s\n' "$1" 2>/dev/null || true
}

attempt_refuse() {
  printf 'qualification: %s\n' "$1" >&2 || true
}

attempt_die() {
  attempt_refuse "$1"
  exit 2
}

attempt_identity_file() { printf '%s/attempt.txt' "$LOG_DIR"; }

attempt_require() {
  if [ -z "${ATTEMPT:-}" ]; then
    attempt_die "set ATTEMPT to a unique identity for this disposable run; a qualification attempt is never anonymous and never inherits another attempt's state"
  fi
}

attempt_recorded() {
  local file
  file="$(attempt_identity_file)"
  [ -s "$file" ] || return 1
  sed -n 's/^attempt=//p' "$file" | head -1
}

attempt_dir_continuation() {
  local recorded
  if recorded="$(attempt_recorded)"; then
    if [ "$recorded" != "$ATTEMPT" ]; then
      attempt_die "$LOG_DIR holds attempt '$recorded'; this run is attempt '$ATTEMPT', and one evidence directory belongs to one attempt"
    fi
    return 0
  fi
  if [ -d "$LOG_DIR" ] && [ -n "$(ls -A "$LOG_DIR" 2>/dev/null)" ]; then
    attempt_die "$LOG_DIR is non-empty and records no attempt; a later attempt does not inherit an unidentified bundle"
  fi
  return 1
}

attempt_write_identity() {
  local file
  file="$(attempt_identity_file)"
  mkdir -p "$LOG_DIR"
  if [ -s "$file" ]; then
    printf 'continued=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$file"
    return 0
  fi
  {
    printf 'attempt=%s\n' "$ATTEMPT"
    printf 'row=%s\n' "${ROW:-}"
    printf 'target=%s\n' "${TARGET:-}"
    printf 'state_key=%s\n' "${STATE_KEY:-}"
    printf 'cluster=%s\n' "${CLUSTER:-}"
    printf 'provider=%s\n' "${PROVIDER:-}"
    printf 'started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$file"
}

attempt_check_fresh() {
  local continuing="$1"
  if ! disposable_state_present; then
    attempt_emit "qualification: fresh disposable target ${TARGET:-} (state key ${STATE_KEY:-})"
    return 0
  fi
  if [ "$continuing" = 1 ] || [ "${CONTINUE_ATTEMPT:-0}" = 1 ]; then
    attempt_emit "qualification: continuing attempt $ATTEMPT against the existing disposable state key ${STATE_KEY:-}"
    return 0
  fi
  attempt_refuse "REFUSING: the disposable state key ${STATE_KEY:-} already exists, so ${TARGET:-} is not a fresh target."
  attempt_refuse "A repeated invocation never reuses an old target as a fresh run. Start a new ATTEMPT with a"
  attempt_refuse "new target, or set CONTINUE_ATTEMPT=1 with the same ATTEMPT to continue this one."
  KEEP=1
  KEEP_REASON="a refused fresh target never tears down a target it did not create"
  exit 2
}

attempt_begin() {
  local check_fresh="${1:-1}" continuing=0
  attempt_require
  if attempt_dir_continuation; then continuing=1; fi
  if [ "$check_fresh" = 1 ]; then attempt_check_fresh "$continuing"; fi
  attempt_write_identity
}
