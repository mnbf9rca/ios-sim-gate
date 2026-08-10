#!/usr/bin/env bash

set -eu

case "${1:-}" in
  list)
    cat "$IOS_SIM_GATE_SIMCTL_DEVICES"
    ;;
  --set)
    [ "${2:-}" = "testing" ] && [ "${3:-}" = "list" ]
    cat "$IOS_SIM_GATE_SIMCTL_TESTING_DEVICES"
    ;;
  shutdown|delete)
    printf '%s %s\n' "$1" "$2" >>"$IOS_SIM_GATE_SIMCTL_LOG"
    ;;
  *)
    printf 'unexpected fake simctl arguments: %s\n' "$*" >&2
    exit 64
    ;;
esac
