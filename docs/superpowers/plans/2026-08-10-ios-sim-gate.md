# ios-sim-gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the machine-wide Bash CLI specified by Family Foqos issue #362, with a global three-run `flock` cap, flat simulator registry, safe cleanup, status, installation, and documentation.

**Architecture:** One Bash executable owns stable Application Support lock files and a JSON registry. Agents register and supply simulator UUIDs; the tool serializes each UUID, admits at most three commands, refreshes `lastupdated`, and runs the child with inherited descriptors. Simulator access is behind an injectable `simctl` command so tests use real registry/lock behavior without CoreSimulator.

**Tech Stack:** Bash 4+, `/opt/homebrew/bin/flock`, `/opt/homebrew/bin/jq`, macOS `xcrun simctl`, plain-Bash tests, ShellCheck.

## Global Constraints

- Work directly on the explicitly authorized `main` branch; never amend or force-push.
- State lives under `~/Library/Application Support/ios-sim-gate/`; lock files are stable and never replaced.
- The registry is `{ UUID: { project, agent, lastupdated, session? } }`; `flock` alone determines liveness.
- The global host cap is three with no project quotas.
- Slot waiting uses one nonblocking availability scan followed by short blocking `flock` waits rotated across enabled slots; there is no tight polling loop and no FIFO guarantee.
- The tool never creates, names, selects, or replaces simulators.
- Cleanup never uses a blanket testing-device-set delete and skips anything not positively attributable.
- Family Foqos adoption files are out of scope.

---

### Task 1: Registry CLI

**Files:**
- Create: `tests/test.sh`
- Create: `tests/helpers/child-env.sh`
- Create: `bin/ios-sim-gate`

**Interfaces:**
- Produces: `register`, `unregister`, and registry validation used by later commands.

- [ ] **Step 1: Write failing registry tests**

Cover initial registration, idempotent refresh, optional session, duplicate `(project, agent, session)` rejection, conflicting UUID ownership, invalid UUID, and corrupt JSON fail-closed behavior. Tests invoke the real CLI with an isolated `IOS_SIM_GATE_HOME` and literal expected JSON values.

- [ ] **Step 2: Run tests and verify RED**

Run: `./tests/test.sh registry`

Expected: FAIL because `bin/ios-sim-gate` does not exist.

- [ ] **Step 3: Implement minimal registry behavior**

Create the Application Support layout under `umask 077`, validate the flat dictionary with `jq`, acquire stable `registry.lock`, and atomically replace only `registry.json`. Reject invalid or conflicting records; never reset corrupt state.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `./tests/test.sh registry`

Expected: all registry cases pass.

- [ ] **Step 5: Commit**

```bash
git add bin/ios-sim-gate tests/test.sh tests/helpers/child-env.sh
git commit -m "feat: add simulator registry commands"
```

### Task 2: Blocking run gate

**Files:**
- Modify: `tests/test.sh`
- Create: `tests/helpers/hold.sh`
- Modify: `bin/ios-sim-gate`

**Interfaces:**
- Produces: `run --project P --agent A [--session S] --udid UUID -- command...` and exported `IOS_SIM_GATE_*` values.

- [ ] **Step 1: Write failing run tests**

Cover environment export, exact child exit status, same-UUID serialization, three concurrent global slots, fourth-run timeout, release after child exit, and no polling dependency. Each UUID is registered first; `hold.sh` keeps a real child alive until its release file appears.

- [ ] **Step 2: Run tests and verify RED**

Run: `./tests/test.sh run`

Expected: FAIL because `run` is not implemented.

- [ ] **Step 3: Implement minimal gate behavior**

Acquire the simulator lock, shared admission lock, and a global slot with inherited descriptors. Scan three slots once; when all are busy, rotate through short bounded blocking `flock` waits until a slot frees or the overall timeout expires. Refresh `lastupdated`, export exact UUID/destination/DerivedData values, and `exec` the child.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `./tests/test.sh run`

Expected: all run and concurrency cases pass.

- [ ] **Step 5: Commit**

```bash
git add bin/ios-sim-gate tests/test.sh tests/helpers/hold.sh
git commit -m "feat: add machine-wide run gate"
```

### Task 3: Cleanup and process-aware status

**Files:**
- Modify: `tests/test.sh`
- Create: `tests/fakes/simctl`
- Modify: `bin/ios-sim-gate`

**Interfaces:**
- Produces: `cleanup`, `reconcile`, and `status`; consumes normalized `simctl list devices --json` and `shutdown/delete UUID` through `IOS_SIM_GATE_SIMCTL_BIN`.

- [ ] **Step 1: Write failing cleanup/status tests**

Cover stale registered deletion, cleanup skipping a held UUID lock, absent-device registry pruning, unregistered normal-set non-deletion, testing-set reporting/skipping, corrupt registry failure, and status showing registry, simulator, lock, and process reality.

- [ ] **Step 2: Run tests and verify RED**

Run: `./tests/test.sh cleanup`

Expected: FAIL because cleanup/status are not implemented.

- [ ] **Step 3: Implement minimal cleanup/status behavior**

Parse default and testing device inventories through the injectable shim. Under `registry.lock`, acquire each candidate UUID lock nonblockingly before deletion. Delete only stale registered devices, skip locked or unregistered devices, never call `delete all`, and remove missing registry entries. Status combines registry data, simulator state, `flock` state, `lsof`, and `pgrep -f UUID` output.

- [ ] **Step 4: Run tests and verify GREEN**

Run: `./tests/test.sh cleanup`

Expected: all cleanup and status cases pass.

- [ ] **Step 5: Commit**

```bash
git add bin/ios-sim-gate tests/test.sh tests/fakes/simctl
git commit -m "feat: add safe cleanup and status"
```

### Task 4: Installer and operator documentation

**Files:**
- Modify: `tests/test.sh`
- Create: `install.sh`
- Create: `README.md`

**Interfaces:**
- Produces: idempotent `~/.local/bin/ios-sim-gate` symlink and complete operator command documentation.

- [ ] **Step 1: Write failing install tests**

Verify first install, repeated install, symlink-to-checkout behavior, Application Support mode, refusal to overwrite a regular destination file, and success when `~/.local/bin` is absent from `PATH` (with warning).

- [ ] **Step 2: Run tests and verify RED**

Run: `./tests/test.sh install`

Expected: FAIL because `install.sh` does not exist.

- [ ] **Step 3: Implement installer and README**

Create/refuse paths safely, symlink rather than copy, and document prerequisites; install; `register`, `unregister`, `run`, `status`, `cleanup`, and `reconcile`; blocking timeout and non-FIFO semantics; exact UUID/no-parallel-testing guidance; accepted idle stale deletion/recreation; and `git pull` upgrades. Omit repository-credit prose.

- [ ] **Step 4: Verify all behavior and static analysis**

Run:

```bash
./tests/test.sh
shellcheck bin/ios-sim-gate install.sh tests/test.sh tests/helpers/*.sh tests/fakes/*
```

Expected: all tests pass and ShellCheck reports no findings.

- [ ] **Step 5: Commit**

```bash
git add README.md install.sh tests/test.sh
git commit -m "docs: add installer and usage guide"
```

### Task 5: Final verification and publish

**Files:**
- Verify only.

- [ ] **Step 1: Review the complete diff and commit history**

Run: `git diff origin/main...HEAD && git log --oneline --decorate origin/main..HEAD`

- [ ] **Step 2: Run fresh verification**

Run:

```bash
./tests/test.sh
shellcheck bin/ios-sim-gate install.sh tests/test.sh tests/helpers/*.sh tests/fakes/*
bash -n bin/ios-sim-gate install.sh tests/test.sh tests/helpers/*.sh tests/fakes/*
```

- [ ] **Step 3: Push authorized `main`**

Run: `git push origin main`

- [ ] **Step 4: Verify remote state**

Run: `git ls-remote --heads origin main` and compare with `git rev-parse HEAD`.
