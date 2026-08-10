#!/usr/bin/env bash

set -eu

ready="$1"
release="$2"

(
  touch "$ready"
  while [ ! -e "$release" ]; do
    sleep 0.02
  done
) </dev/null >/dev/null 2>&1 &
