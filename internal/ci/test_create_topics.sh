#!/usr/bin/env bash
# Behavioral guard for topic establishment (#1157).
#
# Runs the real create-topics.sh against a fake `rpk` whose metadata is driven
# by files, so listing can succeed while creation is selectively denied. The
# helper must not claim the required topics were established unless the
# broker's own metadata says they are.
set -euo pipefail

repo="${1:-$(git rev-parse --show-toplevel)}"
script="$repo/platform/local/scripts/create-topics.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"

cat >"$work/bin/rpk" <<'RPK'
#!/usr/bin/env bash
set -euo pipefail
state="${SOL_TOPICS_TEST_STATE:?}"
printf '%s\n' "$*" >>"$state/invocations"

case "${1:-} ${2:-}" in
  "topic list")
    shift 2
    topic=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --brokers) shift 2 ;;
        --format) shift 2 ;;
        *) topic="$1"; shift ;;
      esac
    done
    if [ -f "$state/list-fails" ]; then
      echo "rpk: unable to dial broker localhost:9092: connection refused" >&2
      exit 1
    fi
    partitions=0
    replicas=0
    if [ -f "$state/topics" ]; then
      while read -r name p r; do
        if [ "$name" = "$topic" ]; then
          partitions="$p"
          replicas="$r"
        fi
      done <"$state/topics"
    fi
    printf '[{"name":"%s","partitions":%s,"replicas":%s}]\n' "$topic" "$partitions" "$replicas"
    ;;
  "topic create")
    shift 2
    topic=""
    parts=0
    reps=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --brokers) shift 2 ;;
        --partitions)
          parts="$2"
          shift 2
          ;;
        --replicas)
          reps="$2"
          shift 2
          ;;
        *)
          topic="$1"
          shift
          ;;
      esac
    done
    if [ -f "$state/create-denied" ]; then
      echo "rpk: unable to create topic '$topic': authorization failed" >&2
      exit 17
    fi
    if [ -f "$state/create-noop" ]; then
      echo "Created topic '$topic'."
      exit 0
    fi
    printf '%s %s %s\n' "$topic" "$parts" "$reps" >>"$state/topics"
    echo "Created topic '$topic'."
    ;;
  *)
    echo "rpk: unexpected invocation: $*" >&2
    exit 2
    ;;
esac
RPK

chmod +x "$work/bin/rpk"
export PATH="$work/bin:$PATH"
export SOL_TOPICS_TEST_STATE="$work/state"

failures=0
ok() { printf '  [OK]   %s\n' "$1"; }
bad() {
  printf '  [FAIL] %s\n' "$1"
  failures=$((failures + 1))
}

reset_state() {
  rm -rf "$work/state"
  mkdir -p "$work/state"
}

status=0
run_script() {
  if "$script" >"$work/out" 2>&1; then
    status=0
  else
    status=$?
  fi
}

expect_exit() {
  if [ "$status" = "$1" ]; then ok "$2"; else bad "$2 (observed exit $status)"; fi
}

expect_text() {
  if grep -qF "$1" "$work/out"; then ok "$2"; else bad "$2"; fi
}

expect_no_text() {
  if grep -qF "$1" "$work/out"; then bad "$2"; else ok "$2"; fi
}

expect_invocation() {
  if grep -qF -- "$1" "$work/state/invocations"; then ok "$2"; else bad "$2"; fi
}

expect_no_invocation() {
  if grep -qF -- "$1" "$work/state/invocations"; then bad "$2"; else ok "$2"; fi
}

echo "create-topics: the broker's own metadata is the success criterion"
reset_state
run_script
expect_exit 0 "an empty broker is populated"
expect_text "Required topics established" "success names what was established"
expect_invocation "topic create sol-demo" "the demo topic was created"
expect_invocation "topic create sol-producer-test" "the producer topic was created"
if grep -c "topic create" "$work/state/invocations" | grep -q '^3$'; then
  ok "every required topic was created once"
else
  bad "the required topics were not each created once"
fi

echo
echo "create-topics: a second run is idempotent"
reset_state
printf 'sol-demo 3 1\nsol-producer-test 3 1\nsol-consumer-test 3 1\n' >"$work/state/topics"
run_script
expect_exit 0 "an already-established broker passes"
expect_no_invocation "topic create" "nothing is recreated"

echo
echo "create-topics: selective create denial fails"
reset_state
touch "$work/state/create-denied"
run_script
expect_exit 1 "a denied create fails the setup"
expect_text "authorization failed" "the broker's original error is visible"
expect_text "could not create topic 'sol-demo'" "the failure names the topic"
expect_no_text "Required topics established" "success is never claimed"

echo
echo "create-topics: a create that does not establish the topic fails"
reset_state
touch "$work/state/create-noop"
run_script
expect_exit 1 "an unestablished required topic fails the setup"
expect_text "was not established" "the missing topic is named"
expect_no_text "Required topics established" "success is never claimed"

echo
echo "create-topics: an incompatible existing shape is refused"
reset_state
printf 'sol-demo 1 1\n' >"$work/state/topics"
run_script
expect_exit 1 "a wrong-shaped topic fails the setup"
expect_text "exists with 1 partitions" "the observed shape is named"
expect_text "expected 3 partitions and 1 replicas" "the required shape is named"

echo
echo "create-topics: an unreachable broker keeps its own evidence"
reset_state
touch "$work/state/list-fails"
run_script
expect_exit 1 "an unreadable broker fails the setup"
expect_text "connection refused" "the broker's original error is visible"

echo
if [ "$failures" -eq 0 ]; then
  echo "create-topics establishment: every expectation held."
  exit 0
fi
echo "create-topics establishment: $failures expectation(s) FAILED."
exit 1
