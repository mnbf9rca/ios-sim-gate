# ios-sim-gate

`ios-sim-gate` coordinates iOS Simulator use across every repository on one Mac. It provides a
machine-wide UUID registry, permanent `flock` coordination files, registry-aware cleanup, and a
hard ceiling of three concurrent simulator/Xcode streams.

The gate does not select, create, clone, rename, or replace simulators. Each agent owns that policy
and registers the exact UUID it chose.

## Requirements and installation

Install Bash, `jq`, and `flock` with Homebrew. The CLI specifically validates
`/opt/homebrew/bin/flock`; its default `jq` path is `/opt/homebrew/bin/jq`.

```bash
./install.sh
```

The idempotent installer links this checkout's CLI to `~/.local/bin/ios-sim-gate`, creates the
private state root, and warns if `~/.local/bin` is not on `PATH`. Upgrade with `git pull` in this
checkout; the symlink continues to point at the updated script.

State lives at `~/Library/Application Support/ios-sim-gate/` with mode `0700`. Registry updates are
atomic. Lock files are permanent coordination inodes and are never unlinked, truncated, replaced,
or moved.

## Usage

Register an agent-selected simulator:

```bash
ios-sim-gate register \
  --project family-foqos \
  --agent build2 \
  --session collab \
  --udid 00000000-0000-0000-0000-000000000000
```

Run a project adapter while holding its UUID lock and one global slot:

```bash
ios-sim-gate run \
  --project family-foqos \
  --agent build2 \
  --session collab \
  --udid 00000000-0000-0000-0000-000000000000 \
  -- ./scripts/project-xcode-adapter.sh
```

The command receives `IOS_SIM_GATE_UDID`, `IOS_SIM_GATE_DESTINATION`,
`IOS_SIM_GATE_DERIVED_DATA_PATH`, `IOS_SIM_GATE_PROJECT`, `IOS_SIM_GATE_AGENT`, and
`IOS_SIM_GATE_SESSION`. `IOS_SIM_GATE_DESTINATION` is always
`platform=iOS Simulator,id=<UUID>`; device-name destinations are not produced.

Inspect or reconcile state:

```bash
ios-sim-gate status
ios-sim-gate cleanup
ios-sim-gate reconcile
```

`status` reports registry attribution, simulator state, UUID/slot lock reality, lock-holder PIDs when
available, and UUID-matching processes. `cleanup` and `reconcile` perform the same bounded sweep.

## Waiting and capacity

The default cap is three. An operator may temporarily lower it to one or two, never raise it:

```bash
IOS_SIM_GATE_CAP=1 ios-sim-gate run ...
```

Waits are bounded by `IOS_SIM_GATE_WAIT_SECONDS` (default 1800 seconds). The implementation first
scans the enabled slot locks once, without polling, then blocks in `flock` on a stable slot. Wake
order is kernel-arbitrary, not FIFO. Strict FIFO would require ticket machinery and is deliberately
omitted unless starvation is observed in practice.

Lock descriptors are inherited by the adapter and its descendants. A surviving descendant keeps
the UUID and global slot locked even if its parent exits. The adapter's exact exit status is returned.

## Cleanup safety

An acquire runs a cleanup sweep while holding `registry.lock`. The default stale interval is seven
days and can be changed with `IOS_SIM_GATE_STALE_SECONDS`.

- A stale registered simulator is shut down and deleted only while its UUID lock is free.
- An unregistered normal-set simulator is deleted only while its UUID lock is free.
- A missing simulator's registry entry is pruned only while its UUID lock is free.
- Every testing-set simulator is report-only. The tool never runs a blanket testing-set delete.
- Every destructive `simctl` operation targets one validated UUID.

An idle registered simulator may be deleted and recreated by its owning agent on the next run. This
is intentional: registry recency does not override the UUID lock as the sole live-use truth.

## Project adapter requirements

Pass the exported exact UUID and DerivedData path directly to Xcode. Every test invocation must use:

```text
-destination "platform=iOS Simulator,id=<UUID>"
-derivedDataPath "<IOS_SIM_GATE_DERIVED_DATA_PATH>"
-parallel-testing-enabled NO
-disable-concurrent-destination-testing
```

Do not use a device name as a destination. Those name-based destinations can create XCTest device
clones. Never clean DerivedData with a wildcard; delete only the active run's exact exported path.

## Development

```bash
./tests/test.sh
shellcheck bin/ios-sim-gate install.sh tests/test.sh tests/helpers/*.sh
```

Tests use a fake `simctl`; they do not boot, create, or delete real simulators.
