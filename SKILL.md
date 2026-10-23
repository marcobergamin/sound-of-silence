---
name: sound-of-silence
description: Enforce pre-execution duration estimation, adaptive timeout guards, periodic progress monitoring, and stall countermeasures when running commands, scripts, or background tasks. Use whenever launching shell commands, build jobs, network operations, or asynchronous processes that could hang or stall.
---
# Sound of Silence (Background Task Watchdog)

> "Hello darkness, my old friend..." — Simon & Garfunkel

Prevent command hangs and silent deadlocks by estimating execution time upfront, configuring adaptive timers, actively polling for forward progress, and executing graduated countermeasures when a stall is detected.

## When to Use

- Launching shell commands, build pipelines, test suites, or network operations that may hang or stall.
- Running asynchronous or background jobs (`&`, `nohup`, daemonized scripts).
- Executing tools that might unexpectedly wait on interactive `stdin`, network timeouts, or resource locks.

## Helper Script (`scripts/watchdog_runner.sh`)

This skill includes a ready-to-use auxiliary script at `scripts/watchdog_runner.sh` that automates the entire watchdog lifecycle:

- **Unbuffered & Non-Interactive Launch:** Redirects `/dev/null` to `stdin` and uses `stdbuf -oL -eL` so output is flushed immediately to the log file.
- **Recursive Process Tree Inspection:** Traverses all child/descendant PIDs (`pgrep -P`) and reads `/proc/<pid>/stat` (`utime` + `stime` CPU ticks and `R`/`D` states) to distinguish silent heavy computation from a true deadlock or hung prompt.
- **Graduated Tree Termination:** Sends `SIGTERM` to the entire process tree (bottom-up), waits up to 5 seconds for graceful shutdown, and escalates to `SIGKILL` for any surviving processes.
- **Exit Codes:**
  - `0` (or command's native exit code): Command completed normally.
  - `124`: Killed due to exceeding the **Hard Timeout**.
  - `125`: Killed due to exceeding the **Inactivity Stall Threshold** (zero log growth and zero CPU/disk activity across the process tree).

### Running the Helper Script

```bash
bash <path_to_skill>/scripts/watchdog_runner.sh \
  -p <POLL_SEC> \
  -s <STALL_SEC> \
  -t <HARD_TIMEOUT_SEC> \
  -l /tmp/task.log \
  -- <COMMAND> [ARGS...]
```

## Workflow

### Step 1: Pre-Execution Duration Estimation

Before launching any non-trivial command, briefly estimate its expected runtime and assign a **Timing Profile**:

| Profile | Expected Duration | Poll Interval (`-p`) | Stall Threshold (`-s`) | Hard Timeout (`-t`) |
| :--- | :--- | :--- | :--- | :--- |
| **Fast** (linting, file ops, quick queries) | less than 15s | `2` | `10` | `30` |
| **Medium** (unit tests, package installs, small builds) | 15s - 2m | `5` | `30` | `180` |
| **Heavy** (full compilations, container builds, large transfers) | 2m - 15m | `15` | `90` | `1200` |

State the chosen profile and timer values briefly before starting the command.

### Step 2: Instrumented Launch

Prefer wrapping the command with `scripts/watchdog_runner.sh` using the profile parameters chosen in Step 1.

If running in an environment where the helper script is not directly invoked, replicate its safeguards manually:

1. **Prevent interactive stdin hangs:** Redirect `/dev/null` into stdin (`< /dev/null`) or pass non-interactive flags (`-y`, `--non-interactive`, `DEBIAN_FRONTEND=noninteractive`).
2. **Capture unbuffered output and PID:** Use `stdbuf -oL -eL` and redirect `stdout` and `stderr` to a dedicated log file, capturing `TASK_PID=$!`.

### Step 3: Periodic Progress Monitoring & Stall Detection

At each **Poll Interval**, verify both liveness and forward progress (handled automatically by `watchdog_runner.sh`):

1. **Check Liveness:** `kill -0 "$TASK_PID" 2>/dev/null`.
2. **Measure Output Progress:** Compare current log file byte count (`wc -c < "$LOG_FILE"`) against the previous poll.
3. **Inspect Process Tree CPU & State:** When no new log output appears, inspect the process and all its children (`pgrep -P`). Verify whether cumulative CPU ticks (`/proc/<pid>/stat` fields `utime` + `stime`) are increasing or any descendant is in `R` (Running) or `D` (Disk I/O) state.
4. **Declare Stall:** If all processes in the tree remain in `S` (Interruptible Sleep) with zero CPU tick progression and zero log growth for longer than the **Stall Threshold**, trigger termination.

### Step 4: Stall Countermeasures & Recovery

When the watchdog triggers (exit code `124` for Hard Timeout or `125` for Inactivity Stall):

1. **Inspect Diagnostic Output:** Review the last 20 lines of `$LOG_FILE` printed by the watchdog.
   - *Interactive prompt detected* (`[y/N]`, password/passphrase prompt, license agreement): Re-run with explicit non-interactive flags (`--yes`, `-f`, `-o BatchMode=yes`).
   - *Network/lock wait detected* (connection retry loop, apt/dpkg lock, git index lock): Clear stale locks if safe, or re-run with explicit tool-level timeouts (`curl --connect-timeout 10 --max-time 30`).
   - *Silent heavy computation hitting Hard Timeout (exit 124):* If the task was actively progressing but simply needed more time, escalate to the next timing profile once.
2. **Report Clearly:** Inform the user of the command executed, the elapsed time, whether it hit a Hard Timeout (`124`) or Inactivity Stall (`125`), the tail of the log, and the recovery action taken.

## Gotchas

- **Buffered stdout:** Many programs buffer `stdout` when redirected to a file, making logs appear frozen while the task is actually working. Always use `stdbuf -oL -eL` and check cumulative CPU ticks across child processes before declaring an inactivity stall.
- **Child processes:** Wrapper scripts (`sh -c`, `make`, `npm`, `cargo`) typically sleep (`S` state, `0%` CPU) while a child process performs the work. Always inspect the full descendant process tree rather than only the root PID.
