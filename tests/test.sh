#!/usr/bin/env bash

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/bin/ios-sim-gate"
INSTALLER="$ROOT/install.sh"
ENV_HELPER="$ROOT/tests/helpers/child-env.sh"
HOLD_HELPER="$ROOT/tests/helpers/hold.sh"
HOLD_LOCK_HELPER="$ROOT/tests/helpers/hold-lock.sh"
FAKE_SIMCTL="$ROOT/tests/helpers/fake-simctl.sh"
SPAWN_HOLDER_HELPER="$ROOT/tests/helpers/spawn-holder.sh"
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

assert_not_contains() {
  local name="$1"
  local needle="$2"
  local haystack="$3"
  case "$haystack" in
    *"$needle"*) fail "$name" "expected output not to contain '$needle'; output: $haystack" ;;
    *) pass "$name" ;;
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
  export IOS_SIM_GATE_SIMCTL_BIN="$FAKE_SIMCTL"
  export IOS_SIM_GATE_SIMCTL_DEVICES="$TEST_ROOT/devices.json"
  export IOS_SIM_GATE_SIMCTL_TESTING_DEVICES="$TEST_ROOT/testing-devices.json"
  export IOS_SIM_GATE_SIMCTL_LOG="$TEST_ROOT/simctl.log"
  printf '{"devices":{}}\n' >"$IOS_SIM_GATE_SIMCTL_DEVICES"
  printf '{"devices":{}}\n' >"$IOS_SIM_GATE_SIMCTL_TESTING_DEVICES"
  : >"$IOS_SIM_GATE_SIMCTL_LOG"
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
  assert_equal "run leaves absent session unset" "" \
    "$(sed -n 's/^IOS_SIM_GATE_SESSION_IS_SET=//p' "$environment_file")"
  assert_equal "run exports stable DerivedData path" \
    "$IOS_SIM_GATE_CACHE_HOME/DerivedData/family-foqos/build2/no-session" \
    "$(sed -n 's/^IOS_SIM_GATE_DERIVED_DATA_PATH=//p' "$environment_file")"
}

test_run_distinguishes_explicit_default_session() {
  setup_test
  local uuid="81222222-2222-2222-2222-222222222222"
  local environment_file="$TEST_ROOT/session-environment"
  register_uuid "$uuid" build2
  run_cli register --project family-foqos --agent build2 --session default \
    --udid 81222222-2222-2222-2222-222222222223
  cat >"$IOS_SIM_GATE_SIMCTL_DEVICES" <<JSON
{"devices":{"runtime":[
  {"udid":"$uuid","name":"No Session","state":"Shutdown"},
  {"udid":"81222222-2222-2222-2222-222222222223","name":"Default Session","state":"Shutdown"}
]}}
JSON

  run_cli run --project family-foqos --agent build2 --session default \
    --udid 81222222-2222-2222-2222-222222222223 -- \
    "$ENV_HELPER" "$environment_file" 0

  assert_equal "explicit default session run succeeds" "0" "$COMMAND_STATUS"
  assert_equal "explicit session is exported" "default" \
    "$(sed -n 's/^IOS_SIM_GATE_SESSION=//p' "$environment_file")"
  assert_equal "explicit session is marked set" "x" \
    "$(sed -n 's/^IOS_SIM_GATE_SESSION_IS_SET=//p' "$environment_file")"
  assert_equal "explicit default gets distinct DerivedData path" \
    "$IOS_SIM_GATE_CACHE_HOME/DerivedData/family-foqos/build2/session-default" \
    "$(sed -n 's/^IOS_SIM_GATE_DERIVED_DATA_PATH=//p' "$environment_file")"
}

test_run_refreshes_stale_entry_before_waiting_for_uuid() {
  setup_test
  local uuid="81333333-3333-3333-3333-333333333333"
  export IOS_SIM_GATE_NOW="2026-08-10T06:00:00Z"
  register_uuid "$uuid" build2
  cat >"$IOS_SIM_GATE_SIMCTL_DEVICES" <<JSON
{"devices":{"runtime":[{"udid":"$uuid","name":"Early Refresh","state":"Shutdown"}]}}
JSON
  "$HOLD_LOCK_HELPER" "$IOS_SIM_GATE_HOME/locks/simulators/$uuid.lock" \
    "$TEST_ROOT/refresh-lock-ready" "$TEST_ROOT/refresh-lock-release" &
  local lock_pid=$!
  wait_for_file "$TEST_ROOT/refresh-lock-ready"
  export IOS_SIM_GATE_NOW="2026-08-10T09:00:00Z"

  IOS_SIM_GATE_WAIT_SECONDS=0 run_cli run --project family-foqos --agent build2 \
    --udid "$uuid" -- /usr/bin/true

  assert_equal "UUID wait still times out" "1" "$COMMAND_STATUS"
  assert_equal "run refreshes owner before UUID wait" "2026-08-10T09:00:00Z" \
    "$(registry_value ".[\"$uuid\"].lastupdated")"
  touch "$TEST_ROOT/refresh-lock-release"
  wait "$lock_pid"
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
  cat >"$IOS_SIM_GATE_SIMCTL_DEVICES" <<JSON
{"devices":{"runtime":[
  {"udid":"$uuid_one","name":"Gate One","state":"Shutdown"},
  {"udid":"$uuid_two","name":"Gate Two","state":"Shutdown"},
  {"udid":"$uuid_three","name":"Gate Three","state":"Shutdown"},
  {"udid":"$uuid_four","name":"Gate Four","state":"Shutdown"}
]}}
JSON

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

test_operator_can_lower_but_not_raise_cap() {
  setup_test
  local uuid_one="85555555-5555-5555-5555-555555555551"
  local uuid_two="85555555-5555-5555-5555-555555555552"
  register_uuid "$uuid_one" build1
  register_uuid "$uuid_two" build2
  cat >"$IOS_SIM_GATE_SIMCTL_DEVICES" <<JSON
{"devices":{"runtime":[
  {"udid":"$uuid_one","name":"Cap One","state":"Shutdown"},
  {"udid":"$uuid_two","name":"Cap Two","state":"Shutdown"}
]}}
JSON

  IOS_SIM_GATE_CAP=1 "$CLI" run --project family-foqos --agent build1 --udid "$uuid_one" -- \
    "$HOLD_HELPER" "$TEST_ROOT/cap-ready" "$TEST_ROOT/cap-release" \
    >"$TEST_ROOT/cap-one.log" 2>&1 &
  local cap_pid=$!
  wait_for_file "$TEST_ROOT/cap-ready"
  IOS_SIM_GATE_CAP=1 IOS_SIM_GATE_WAIT_SECONDS=0 run_cli run \
    --project family-foqos --agent build2 --udid "$uuid_two" -- /usr/bin/true
  assert_equal "lowered cap blocks second run" "1" "$COMMAND_STATUS"
  assert_contains "lowered cap reports global timeout" "global simulator slot" "$COMMAND_OUTPUT"
  touch "$TEST_ROOT/cap-release"
  wait "$cap_pid"

  IOS_SIM_GATE_CAP=4 run_cli status
  assert_equal "cap above three is rejected" "1" "$COMMAND_STATUS"
  assert_contains "cap rejection explains range" "between 1 and 3" "$COMMAND_OUTPUT"

  IOS_SIM_GATE_CAP=1 run_cli status
  assert_equal "lowered-cap status succeeds" "0" "$COMMAND_STATUS"
  assert_contains "lowered-cap status reports one slot" "capacity slots=1" "$COMMAND_OUTPUT"
  assert_not_contains "lowered-cap status hides disabled slot two" "slot=2" "$COMMAND_OUTPUT"
  assert_not_contains "lowered-cap status hides disabled slot three" "slot=3" "$COMMAND_OUTPUT"
}

test_descendant_inherits_uuid_and_slot_locks() {
  setup_test
  local uuid="86666666-6666-6666-6666-666666666666"
  register_uuid "$uuid" build2
  cat >"$IOS_SIM_GATE_SIMCTL_DEVICES" <<JSON
{"devices":{"runtime":[{"udid":"$uuid","name":"Inherited","state":"Shutdown"}]}}
JSON

  run_cli run --project family-foqos --agent build2 --udid "$uuid" -- \
    "$SPAWN_HOLDER_HELPER" "$TEST_ROOT/descendant-ready" "$TEST_ROOT/descendant-release"
  assert_equal "wrapper exits after spawning descendant" "0" "$COMMAND_STATUS"
  wait_for_file "$TEST_ROOT/descendant-ready"

  IOS_SIM_GATE_WAIT_SECONDS=0 run_cli run --project family-foqos --agent build2 \
    --udid "$uuid" -- /usr/bin/true
  assert_equal "descendant retains inherited UUID lock" "1" "$COMMAND_STATUS"
  assert_contains "descendant lock rejection names UUID" "simulator $uuid" "$COMMAND_OUTPUT"
  touch "$TEST_ROOT/descendant-release"
}

test_waiter_rotates_when_a_different_slot_frees() {
  setup_test
  local uuid="87777777-7777-7777-7777-777777777777"
  local checksum
  local first_slot
  local released_slot
  local slot
  local holder_pids=""
  register_uuid "$uuid" build2
  cat >"$IOS_SIM_GATE_SIMCTL_DEVICES" <<JSON
{"devices":{"runtime":[{"udid":"$uuid","name":"Rotating Waiter","state":"Shutdown"}]}}
JSON
  checksum="$(printf '%s' "$uuid" | cksum)"
  checksum="${checksum%% *}"
  first_slot=$((checksum % 3 + 1))
  released_slot=$((first_slot % 3 + 1))

  for slot in 1 2 3; do
    "$HOLD_LOCK_HELPER" "$IOS_SIM_GATE_HOME/locks/slots/$slot.lock" \
      "$TEST_ROOT/slot-ready-$slot" "$TEST_ROOT/slot-release-$slot" &
    holder_pids="$holder_pids $!"
    wait_for_file "$TEST_ROOT/slot-ready-$slot"
  done

  IOS_SIM_GATE_WAIT_SECONDS=8 IOS_SIM_GATE_SLOT_SLICE_SECONDS=1 \
    "$CLI" run --project family-foqos --agent build2 --udid "$uuid" -- \
      /usr/bin/touch "$TEST_ROOT/rotated-start" >"$TEST_ROOT/rotated.log" 2>&1 &
  local waiter_pid=$!
  sleep 0.15
  touch "$TEST_ROOT/slot-release-$released_slot"
  if wait_for_file "$TEST_ROOT/rotated-start"; then
    pass "waiter rotates to a different freed slot"
  else
    fail "waiter rotates to a different freed slot" \
      "waiter remained pinned to slot $first_slot after slot $released_slot was freed"
  fi

  touch "$TEST_ROOT/slot-release-1" "$TEST_ROOT/slot-release-2" "$TEST_ROOT/slot-release-3"
  wait "$waiter_pid"
  for slot in $holder_pids; do
    wait "$slot"
  done
}

test_refresh_registry_wait_uses_remaining_budget() {
  setup_test
  local uuid="88888888-8888-8888-8888-888888888888"
  register_uuid "$uuid" build2
  cat >"$IOS_SIM_GATE_SIMCTL_DEVICES" <<JSON
{"devices":{"runtime":[{"udid":"$uuid","name":"Budgeted Wait","state":"Shutdown"}]}}
JSON
  "$HOLD_LOCK_HELPER" "$IOS_SIM_GATE_HOME/locks/simulators/$uuid.lock" \
    "$TEST_ROOT/budget-uuid-ready" "$TEST_ROOT/budget-uuid-release" &
  local uuid_lock_pid=$!
  wait_for_file "$TEST_ROOT/budget-uuid-ready"

  (
    set +e
    IOS_SIM_GATE_WAIT_SECONDS=3 "$CLI" run --project family-foqos --agent build2 \
      --udid "$uuid" -- /usr/bin/true >"$TEST_ROOT/budget-run.log" 2>&1
    printf '%s\n' "$?" >"$TEST_ROOT/budget-run-status"
  ) &
  local run_pid=$!
  sleep 1.1
  "$HOLD_LOCK_HELPER" "$IOS_SIM_GATE_HOME/locks/registry.lock" \
    "$TEST_ROOT/budget-registry-ready" "$TEST_ROOT/budget-registry-release" &
  local registry_lock_pid=$!
  wait_for_file "$TEST_ROOT/budget-registry-ready"
  touch "$TEST_ROOT/budget-uuid-release"
  wait "$uuid_lock_pid"
  wait "$run_pid"

  assert_equal "refresh registry wait times out" "1" \
    "$(tr -d '\n' <"$TEST_ROOT/budget-run-status")"
  assert_contains "refresh timeout names registry lock" "waiting for registry lock" \
    "$(cat "$TEST_ROOT/budget-run.log")"
  assert_not_contains "refresh registry wait does not restart full budget" \
    "after 3s waiting for registry lock" "$(cat "$TEST_ROOT/budget-run.log")"
  touch "$TEST_ROOT/budget-registry-release"
  wait "$registry_lock_pid"
}

run_run_tests() {
  test_run_exports_environment_and_preserves_exit_status
  test_run_distinguishes_explicit_default_session
  test_run_refreshes_stale_entry_before_waiting_for_uuid
  test_run_rejects_registry_owner_mismatch
  test_same_uuid_runs_serialize
  test_global_cap_allows_three_and_times_out_fourth
  test_operator_can_lower_but_not_raise_cap
  test_descendant_inherits_uuid_and_slot_locks
  test_waiter_rotates_when_a_different_slot_frees
  test_refresh_registry_wait_uses_remaining_budget
}

write_cleanup_inventory() {
  cat >"$IOS_SIM_GATE_SIMCTL_DEVICES" <<'JSON'
{"devices":{"runtime":[
  {"udid":"91111111-1111-1111-1111-111111111111","name":"Stale Registered","state":"Shutdown","dataPathSize":101},
  {"udid":"92222222-2222-2222-2222-222222222222","name":"Fresh Registered","state":"Shutdown","dataPathSize":202},
  {"udid":"93333333-3333-3333-3333-333333333333","name":"Locked Registered","state":"Booted","dataPathSize":303},
  {"udid":"94444444-4444-4444-4444-444444444444","name":"Unregistered Normal","state":"Shutdown","dataPathSize":404}
]}}
JSON
  cat >"$IOS_SIM_GATE_SIMCTL_TESTING_DEVICES" <<'JSON'
{"devices":{"runtime":[
  {"udid":"95555555-5555-5555-5555-555555555555","name":"Clone 1 of iPhone 17","state":"Shutdown","dataPathSize":505}
]}}
JSON
}

test_cleanup_respects_registry_locks_and_testing_set() {
  setup_test
  write_cleanup_inventory
  export IOS_SIM_GATE_STALE_SECONDS=3600
  export IOS_SIM_GATE_NOW="2026-08-10T06:00:00Z"
  register_uuid 91111111-1111-1111-1111-111111111111 stale
  register_uuid 93333333-3333-3333-3333-333333333333 locked
  register_uuid 96666666-6666-6666-6666-666666666666 missing
  export IOS_SIM_GATE_NOW="2026-08-10T09:00:00Z"
  register_uuid 92222222-2222-2222-2222-222222222222 fresh

  mkdir -p "$IOS_SIM_GATE_HOME/locks/simulators"
  "$HOLD_LOCK_HELPER" \
    "$IOS_SIM_GATE_HOME/locks/simulators/93333333-3333-3333-3333-333333333333.lock" \
    "$TEST_ROOT/lock-ready" "$TEST_ROOT/lock-release" &
  local lock_pid=$!
  wait_for_file "$TEST_ROOT/lock-ready"

  run_cli cleanup

  assert_equal "cleanup succeeds" "0" "$COMMAND_STATUS"
  assert_contains "cleanup logs stale attribution" \
    "uuid=91111111-1111-1111-1111-111111111111 owner=family-foqos/stale/default" \
    "$COMMAND_OUTPUT"
  assert_contains "cleanup logs stale reason" "reason=stale" "$COMMAND_OUTPUT"
  assert_contains "cleanup logs approximate bytes" "bytes=101" "$COMMAND_OUTPUT"
  assert_contains "cleanup reports held UUID" \
    "uuid=93333333-3333-3333-3333-333333333333 reason=locked" "$COMMAND_OUTPUT"
  assert_contains "cleanup reports testing fixture" \
    "uuid=95555555-5555-5555-5555-555555555555 name=Clone 1 of iPhone 17 state=Shutdown bytes=505 reason=testing-set-report-only" \
    "$COMMAND_OUTPUT"
  assert_equal "cleanup keeps fresh registry entry" "true" \
    "$(registry_value 'has("92222222-2222-2222-2222-222222222222")')"
  assert_equal "cleanup keeps locked registry entry" "true" \
    "$(registry_value 'has("93333333-3333-3333-3333-333333333333")')"
  assert_equal "cleanup removes stale registry entry" "false" \
    "$(registry_value 'has("91111111-1111-1111-1111-111111111111")')"
  assert_equal "cleanup prunes missing registry entry" "false" \
    "$(registry_value 'has("96666666-6666-6666-6666-666666666666")')"
  assert_contains "cleanup deletes exact stale UUID" \
    "delete 91111111-1111-1111-1111-111111111111" \
    "$(cat "$IOS_SIM_GATE_SIMCTL_LOG")"
  assert_not_contains "cleanup never deletes unregistered normal UUID" \
    "94444444-4444-4444-4444-444444444444" \
    "$(cat "$IOS_SIM_GATE_SIMCTL_LOG")"
  assert_not_contains "cleanup does not clutter output with unregistered normal UUID" \
    "94444444-4444-4444-4444-444444444444" "$COMMAND_OUTPUT"
  case "$(cat "$IOS_SIM_GATE_SIMCTL_LOG")" in
    *95555555-5555-5555-5555-555555555555*)
      fail "cleanup never deletes testing fixture" "testing UUID reached destructive simctl" ;;
    *) pass "cleanup never deletes testing fixture" ;;
  esac

  touch "$TEST_ROOT/lock-release"
  wait "$lock_pid"
}

test_status_reports_registry_inventory_and_process_reality() {
  setup_test
  write_cleanup_inventory
  register_uuid 92222222-2222-2222-2222-222222222222 fresh

  run_cli status

  assert_equal "status succeeds" "0" "$COMMAND_STATUS"
  assert_contains "status reports registered owner" \
    "uuid=92222222-2222-2222-2222-222222222222 owner=family-foqos/fresh/default" \
    "$COMMAND_OUTPUT"
  assert_contains "status reports simulator state" "state=Shutdown" "$COMMAND_OUTPUT"
  assert_contains "status reports free UUID lock" "lock=free" "$COMMAND_OUTPUT"
  assert_contains "status reports unregistered simulator" \
    "uuid=94444444-4444-4444-4444-444444444444 owner=unregistered" \
    "$COMMAND_OUTPUT"
  assert_contains "status labels testing fixture report-only" \
    "uuid=95555555-5555-5555-5555-555555555555 owner=testing-set-report-only" \
    "$COMMAND_OUTPUT"
}

test_cleanup_removes_inventory_temps_when_simctl_data_is_invalid() {
  setup_test
  printf 'not-json\n' >"$IOS_SIM_GATE_SIMCTL_TESTING_DEVICES"

  run_cli cleanup

  assert_equal "invalid simctl inventory fails cleanup" "1" "$COMMAND_STATUS"
  assert_contains "invalid inventory explains failure" \
    "simctl returned an invalid device inventory" "$COMMAND_OUTPUT"
  local leftovers
  leftovers="$(find "$IOS_SIM_GATE_HOME" -maxdepth 1 -type f \
    \( -name '.devices.*' -o -name '.testing-devices.*' -o -name '.registry.*' \) -print)"
  assert_equal "failed cleanup removes tracked temp files" "" "$leftovers"
}

run_cleanup_tests() {
  test_cleanup_respects_registry_locks_and_testing_set
  test_status_reports_registry_inventory_and_process_reality
  test_cleanup_removes_inventory_temps_when_simctl_data_is_invalid
}

run_installer() {
  set +e
  COMMAND_OUTPUT="$(HOME="$TEST_ROOT/home" PATH="/usr/bin:/bin" "$INSTALLER" 2>&1)"
  COMMAND_STATUS=$?
  set -e
}

assert_file_contains() {
  local name="$1"
  local needle="$2"
  local path="$3"
  if [ -f "$path" ] && grep -Fq -- "$needle" "$path"; then
    pass "$name"
  else
    fail "$name" "expected $path to contain '$needle'"
  fi
}

test_version_and_installer_contract() {
  setup_test
  run_cli --version
  assert_equal "version command succeeds" "0" "$COMMAND_STATUS"
  assert_equal "version command is machine-readable" "ios-sim-gate 0.1.0" "$COMMAND_OUTPUT"

  run_installer
  assert_equal "installer succeeds" "0" "$COMMAND_STATUS"
  assert_equal "installer links CLI to checkout" "$CLI" \
    "$(readlink "$TEST_ROOT/home/.local/bin/ios-sim-gate")"
  assert_equal "installer creates private state root" "700" \
    "$(stat -f '%Lp' "$TEST_ROOT/home/Library/Application Support/ios-sim-gate")"
  assert_contains "installer warns when local bin is absent from PATH" \
    ".local/bin is not on PATH" "$COMMAND_OUTPUT"

  run_installer
  assert_equal "installer is idempotent" "0" "$COMMAND_STATUS"
  assert_equal "idempotent install preserves target" "$CLI" \
    "$(readlink "$TEST_ROOT/home/.local/bin/ios-sim-gate")"
}

test_installer_refuses_regular_file_collision() {
  setup_test
  mkdir -p "$TEST_ROOT/home/.local/bin"
  printf 'keep-me\n' >"$TEST_ROOT/home/.local/bin/ios-sim-gate"

  run_installer

  assert_equal "installer rejects regular-file collision" "1" "$COMMAND_STATUS"
  assert_contains "installer explains collision" "refusing to replace non-symlink" "$COMMAND_OUTPUT"
  assert_equal "installer preserves collided file" "keep-me" \
    "$(tr -d '\n' <"$TEST_ROOT/home/.local/bin/ios-sim-gate")"
}

test_readme_records_safety_and_wait_contracts() {
  assert_file_contains "README documents kernel-arbitrary wake order" \
    "kernel-arbitrary, not FIFO" "$ROOT/README.md"
  assert_file_contains "README documents accepted stale recreation" \
    "deleted and recreated" "$ROOT/README.md"
  assert_file_contains "README documents exact UUID destination" \
    "platform=iOS Simulator,id=<UUID>" "$ROOT/README.md"
  assert_file_contains "README disables parallel test workers" \
    "-parallel-testing-enabled NO" "$ROOT/README.md"
  assert_file_contains "README disables concurrent destinations" \
    "-disable-concurrent-destination-testing" "$ROOT/README.md"
  assert_file_contains "README states no allocation policy" \
    "does not select, create, clone, rename, or replace simulators" "$ROOT/README.md"
  if grep -Eq '(^|[[:space:]])sleep([[:space:]]|$)' "$CLI"; then
    fail "gate implementation has no polling sleep" "found sleep in $CLI"
  else
    pass "gate implementation has no polling sleep"
  fi
  if grep -Eq 'simctl[[:space:]]+(create|clone)' "$CLI"; then
    fail "gate implementation has no allocation operations" "found create/clone in $CLI"
  else
    pass "gate implementation has no allocation operations"
  fi
}

run_install_tests() {
  test_version_and_installer_contract
  test_installer_refuses_regular_file_collision
  test_readme_records_safety_and_wait_contracts
}

case "$GROUP" in
  all) run_registry_tests; run_run_tests; run_cleanup_tests; run_install_tests ;;
  registry) run_registry_tests ;;
  run) run_run_tests ;;
  cleanup) run_cleanup_tests ;;
  install) run_install_tests ;;
  *) printf 'unknown test group: %s\n' "$GROUP" >&2; exit 2 ;;
esac

[ -z "$TEST_ROOT" ] || rm -rf "$TEST_ROOT"
printf '%s passed; %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
