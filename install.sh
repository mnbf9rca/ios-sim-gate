#!/usr/bin/env bash

set -eu

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_cli="$script_root/bin/ios-sim-gate"
install_dir="$HOME/.local/bin"
installed_cli="$install_dir/ios-sim-gate"
state_root="$HOME/Library/Application Support/ios-sim-gate"

[ -x "$source_cli" ] || {
  printf 'install: CLI is not executable: %s\n' "$source_cli" >&2
  exit 1
}

umask 077
mkdir -p "$install_dir" "$state_root"
chmod 700 "$state_root"

if [ -e "$installed_cli" ] && [ ! -L "$installed_cli" ]; then
  printf 'install: refusing to replace non-symlink: %s\n' "$installed_cli" >&2
  exit 1
fi

if [ ! -L "$installed_cli" ] || [ "$(readlink "$installed_cli")" != "$source_cli" ]; then
  ln -sfn "$source_cli" "$installed_cli"
fi

printf 'installed %s -> %s\n' "$installed_cli" "$source_cli"
case ":${PATH:-}:" in
  *":$install_dir:"*) ;;
  *) printf 'warning: %s is not on PATH\n' "$install_dir" >&2 ;;
esac
