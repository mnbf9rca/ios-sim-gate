#!/usr/bin/env bash

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/bin/ios-sim-gate"
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

case "$GROUP" in
  all|registry) run_registry_tests ;;
  *) printf 'unknown test group: %s\n' "$GROUP" >&2; exit 2 ;;
esac

[ -z "$TEST_ROOT" ] || rm -rf "$TEST_ROOT"
printf '%s passed; %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
