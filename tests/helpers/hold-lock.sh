#!/usr/bin/env bash

set -eu

lock_path="$1"
ready="$2"
release="$3"
flock_bin="${IOS_SIM_GATE_FLOCK_BIN:-/opt/homebrew/bin/flock}"

exec 8>>"$lock_path"
"$flock_bin" -x 8
touch "$ready"
while [ ! -e "$release" ]; do
  sleep 0.02
done
