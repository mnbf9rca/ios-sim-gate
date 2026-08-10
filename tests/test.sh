#!/usr/bin/env bash

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/bin/ios-sim-gate"
ENV_HELPER="$ROOT/tests/helpers/child-env.sh"
HOLD_HELPER="$ROOT/tests/helpers/hold.sh"
JQ_BIN="${IOS_SIM_GATE_TEST_JQ_BIN:-/opt/homebrew/bin/jq}"
GROUP="${1:-all}"
PASS_COUNT=0
FAIL_COUNT=0
TEST_ROOT=""
COMMAND_OUTPUT=""
COMMAND_STATUS=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'not ok - %s\n  %s\n' "$1" "$2"
}

assert_equal() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$name"
  else
    fail "$name" "expected '$expected', got '$actual'"
  fi
}

assert_contains() {
  local name="$1"
  local needle="$2"
  local haystack="$3"
  case "$haystack" in
    *"$needle"*) pass "$name" ;;
    *) fail "$name" "expected output to contain '$needle'; output: $haystack" ;;
  esac
}

setup_test() {
  [ -z "$TEST_ROOT" ] || rm -rf "$TEST_ROOT"
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ios-sim-gate-test.XXXXXX")"
  export IOS_SIM_GATE_HOME="$TEST_ROOT/state"
  export IOS_SIM_GATE_NOW="2026-08-10T08:00:00Z"
  export IOS_SIM_GATE_JQ_BIN="$JQ_BIN"
  export IOS_SIM_GATE_CACHE_HOME="$TEST_ROOT/cache"
  export IOS_SIM_GATE_WAIT_SECONDS=2
}

run_cli() {
  set +e
  COMMAND_OUTPUT="$("$CLI" "$@" 2>&1)"
  COMMAND_STATUS=$?
  set -e
}

registry_value() {
  "$JQ_BIN" -r "$1" "$IOS_SIM_GATE_HOME/registry.json"
}

wait_for_file() {
  local path="$1"
  local attempts=0
  while [ ! -e "$path" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -e "$path" ]
}

register_uuid() {
  local uuid="$1"
  local agent="$2"
  "$CLI" register --project family-foqos --agent "$agent" --udid "$uuid" >/dev/null
}

test_register_creates_flat_entry() {
  setup_test
  run_cli register --project family-foqos --agent build2 \
    --udid 11111111-1111-1111-1111-111111111111

  assert_equal "register succeeds" "0" "$COMMAND_STATUS"
  assert_equal "register stores project" "family-foqos" \
    "$(registry_value '.["11111111-1111-1111-1111-111111111111"].project')"
  assert_equal "register stores agent" "build2" \
    "$(registry_value '.["11111111-1111-1111-1111-111111111111"].agent')"
  assert_equal "register stores lastupdated" "2026-08-10T08:00:00Z" \
    "$(registry_value '.["11111111-1111-1111-1111-111111111111"].lastupdated')"
  assert_equal "register omits absent session" "false" \
    "$(registry_value '.["11111111-1111-1111-1111-111111111111"] | has("session")')"
}

test_register_stores_optional_session() {
  setup_test
  run_cli register --project family-foqos --agent build2 --session collab \
    --udid 22222222-2222-2222-2222-222222222222

  assert_equal "session register succeeds" "0" "$COMMAND_STATUS"
  assert_equal "register stores session" "collab" \
    "$(registry_value '.["22222222-2222-2222-2222-222222222222"].session')"
}

test_register_refreshes_one_existing_entry() {
  setup_test
  run_cli register --project family-foqos --agent build2 --session collab \
    --udid 33333333-3333-3333-3333-333333333333
  export IOS_SIM_GATE_NOW="2026-08-10T09:30:00Z"
  run_cli register --project family-foqos --agent build2 --session collab \
    --udid 33333333-3333-3333-3333-333333333333

  assert_equal "idempotent register succeeds" "0" "$COMMAND_STATUS"
  assert_equal "idempotent register keeps one entry" "1" \
    "$(registry_value 'length')"
  assert_equal "idempotent register refreshes timestamp" "2026-08-10T09:30:00Z" \
    "$(registry_value '.["33333333-3333-3333-3333-333333333333"].lastupdated')"
}

test_register_rejects_duplicate_owner_tuple() {
  setup_test
  run_cli register --project family-foqos --agent build2 --session collab \
    --udid 44444444-4444-4444-4444-444444444444
  run_cli register --project family-foqos --agent build2 --session collab \
    --udid 55555555-5555-5555-5555-555555555555

  assert_equal "duplicate owner is rejected" "1" "$COMMAND_STATUS"
  assert_contains "duplicate owner explains conflict" "already owns simulator" "$COMMAND_OUTPUT"
  assert_equal "duplicate owner does not mutate registry" "1" \
    "$(registry_value 'length')"
}

test_register_rejects_uuid_owned_by_someone_else() {
  setup_test
  run_cli register --project family-foqos --agent build2 \
    --udid 66666666-6666-6666-6666-666666666666
  run_cli register --project making-tracks --agent codex1 \
    --udid 66666666-6666-6666-6666-666666666666

  assert_equal "conflicting UUID ownership is rejected" "1" "$COMMAND_STATUS"
  assert_contains "conflicting UUID explains ownership" "registered to another owner" "$COMMAND_OUTPUT"
}

test_register_rejects_invalid_uuid() {
  setup_test
  run_cli register --project family-foqos --agent build2 --udid not-a-uuid

  assert_equal "invalid UUID is rejected" "1" "$COMMAND_STATUS"
  assert_contains "invalid UUID explains validation" "invalid simulator UUID" "$COMMAND_OUTPUT"
}

test_corrupt_registry_fails_closed() {
  setup_test
  mkdir -p "$IOS_SIM_GATE_HOME"
  printf '{broken\n' >"$IOS_SIM_GATE_HOME/registry.json"
  run_cli register --project family-foqos --agent build2 \
    --udid 77777777-7777-7777-7777-777777777777

  assert_equal "corrupt registry is rejected" "1" "$COMMAND_STATUS"
  assert_contains "corrupt registry reports failure" "registry is invalid" "$COMMAND_OUTPUT"
  assert_equal "corrupt registry is not overwritten" "{broken" \
    "$(tr -d '\n' <"$IOS_SIM_GATE_HOME/registry.json")"
}

run_registry_tests() {
  test_register_creates_flat_entry
  test_register_stores_optional_session
  test_register_refreshes_one_existing_entry
  test_register_rejects_duplicate_owner_tuple
  test_register_rejects_uuid_owned_by_someone_else
  test_register_rejects_invalid_uuid
  test_corrupt_registry_fails_closed
}

test_run_exports_environment_and_preserves_exit_status() {
  setup_test
  local uuid="81111111-1111-1111-1111-111111111111"
  local environment_file="$TEST_ROOT/environment"
  register_uuid "$uuid" build2

  run_cli run --project family-foqos --agent build2 --udid "$uuid" -- \
    "$ENV_HELPER" "$environment_file" 23

  assert_equal "run preserves child exit status" "23" "$COMMAND_STATUS"
  assert_equal "run exports UUID" "$uuid" \
    "$(sed -n 's/^IOS_SIM_GATE_UDID=//p' "$environment_file")"
  assert_equal "run exports UUID destination" "platform=iOS Simulator,id=$uuid" \
    "$(sed -n 's/^IOS_SIM_GATE_DESTINATION=//p' "$environment_file")"
  assert_equal "run exports project" "family-foqos" \
    "$(sed -n 's/^IOS_SIM_GATE_PROJECT=//p' "$environment_file")"
  assert_equal "run exports agent" "build2" \
    "$(sed -n 's/^IOS_SIM_GATE_AGENT=//p' "$environment_file")"
  assert_equal "run exports empty session" "" \
    "$(sed -n 's/^IOS_SIM_GATE_SESSION=//p' "$environment_file")"
  assert_equal "run exports stable DerivedData path" \
    "$IOS_SIM_GATE_CACHE_HOME/DerivedData/family-foqos/build2/default" \
    "$(sed -n 's/^IOS_SIM_GATE_DERIVED_DATA_PATH=//p' "$environment_file")"
}

test_run_rejects_registry_owner_mismatch() {
  setup_test
  local uuid="82222222-2222-2222-2222-222222222222"
  register_uuid "$uuid" build2

  run_cli run --project family-foqos --agent other --udid "$uuid" -- /usr/bin/true

  assert_equal "run rejects wrong owner" "1" "$COMMAND_STATUS"
  assert_contains "run explains wrong owner" "does not own simulator" "$COMMAND_OUTPUT"
}

test_same_uuid_runs_serialize() {
  setup_test
  local uuid="83333333-3333-3333-3333-333333333333"
  local ready_one="$TEST_ROOT/ready-one"
  local ready_two="$TEST_ROOT/ready-two"
  local release_one="$TEST_ROOT/release-one"
  local release_two="$TEST_ROOT/release-two"
  register_uuid "$uuid" build2

  "$CLI" run --project family-foqos --agent build2 --udid "$uuid" -- \
    "$HOLD_HELPER" "$ready_one" "$release_one" >"$TEST_ROOT/one.log" 2>&1 &
  local pid_one=$!
  if wait_for_file "$ready_one"; then
    pass "first same-UUID run starts"
  else
    fail "first same-UUID run starts" "first child never became ready"
  fi

  "$CLI" run --project family-foqos --agent build2 --udid "$uuid" -- \
    "$HOLD_HELPER" "$ready_two" "$release_two" >"$TEST_ROOT/two.log" 2>&1 &
  local pid_two=$!
  sleep 0.15
  if [ ! -e "$ready_two" ]; then
    pass "second same-UUID run waits"
  else
    fail "second same-UUID run waits" "second child started while UUID was locked"
  fi

  touch "$release_one"
  if wait_for_file "$ready_two"; then
    pass "second same-UUID run starts after release"
  else
    fail "second same-UUID run starts after release" "second child never became ready"
  fi
  touch "$release_two"
  wait "$pid_one"
  wait "$pid_two"
}

test_global_cap_allows_three_and_times_out_fourth() {
  setup_test
  local uuid_one="84444444-4444-4444-4444-444444444441"
  local uuid_two="84444444-4444-4444-4444-444444444442"
  local uuid_three="84444444-4444-4444-4444-444444444443"
  local uuid_four="84444444-4444-4444-4444-444444444444"
  local pids=""
  local index
  local uuid
  register_uuid "$uuid_one" build1
  register_uuid "$uuid_two" build2
  register_uuid "$uuid_three" build3
  register_uuid "$uuid_four" build4

  index=1
  for uuid in "$uuid_one" "$uuid_two" "$uuid_three"; do
    "$CLI" run --project family-foqos --agent "build$index" --udid "$uuid" -- \
      "$HOLD_HELPER" "$TEST_ROOT/ready-$index" "$TEST_ROOT/release-$index" \
      >"$TEST_ROOT/run-$index.log" 2>&1 &
    pids="$pids $!"
    index=$((index + 1))
  done

  if wait_for_file "$TEST_ROOT/ready-1" && wait_for_file "$TEST_ROOT/ready-2" &&
     wait_for_file "$TEST_ROOT/ready-3"; then
    pass "three distinct UUID runs start concurrently"
  else
    fail "three distinct UUID runs start concurrently" "one of the three children did not start"
  fi

  IOS_SIM_GATE_WAIT_SECONDS=0 run_cli run --project family-foqos --agent build4 \
    --udid "$uuid_four" -- /usr/bin/true
  assert_equal "fourth run times out at global cap" "1" "$COMMAND_STATUS"
  assert_contains "fourth run explains global timeout" "global simulator slot" "$COMMAND_OUTPUT"

  touch "$TEST_ROOT/release-1" "$TEST_ROOT/release-2" "$TEST_ROOT/release-3"
  for index in $pids; do
    wait "$index"
  done
}

run_run_tests() {
  test_run_exports_environment_and_preserves_exit_status
  test_run_rejects_registry_owner_mismatch
  test_same_uuid_runs_serialize
  test_global_cap_allows_three_and_times_out_fourth
}

case "$GROUP" in
  all) run_registry_tests; run_run_tests ;;
  registry) run_registry_tests ;;
  run) run_run_tests ;;
  *) printf 'unknown test group: %s\n' "$GROUP" >&2; exit 2 ;;
esac

[ -z "$TEST_ROOT" ] || rm -rf "$TEST_ROOT"
printf '%s passed; %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
