---
name: stack-up
description: Run, read and adapt stack-up, a bash tool that starts a local development stack from one stack.conf file in ordered stages, proves each service is ready, names an owner for each failure, and signals only the processes it launched (--stop, and a start for an option that is off with when_off = stop, also ask compose to stop its services under the project name). Use it to plan or explain a stack-up run, write or fix a stack.conf, read its run logs and history, or port the tool to another platform.
license: MIT
compatibility: macOS with the stock bash 3.2, lsof, pgrep, nc, curl and a lockf that locks an open file descriptor (the form current macOS documents; older releases may lack it). I have not tested Linux; a port there needs lsof, procps (pgrep), flock and an OpenBSD-style nc (netcat-openbsd). Windows needs WSL or a port.
metadata:
  version: 0.1.0
  repository: https://github.com/priyesh0453/stack-up
---

# stack-up

stack-up reads `stack.conf`, validates all of it, then runs its stages in order (inside a stage, dependencies first, then file order), with `[check]`s at the end of their stage and a smoke check at the end. It records every service it launches, and `--stop` signals only those launches (and asks compose to stop its services under the project name, as a start does for an option that is off with `when_off = stop`); a command run under a deadline is stopped when its deadline passes, and its own keep-awake helper is stopped as a run ends.

## Start with the read-only modes

Use these first, and show the person the output. None of them starts anything or writes a file.

| command | answers |
|---|---|
| `bin/stack-up --config PATH --plan` | what would run, in which order, with which readiness probe and deadline, and what would be repaired |
| `bin/stack-up --config PATH --print-config` | what the file actually says, as `kind\|name\|key\|value` rows |
| `bin/stack-up --print-schema` | every key, its type and default |
| `bin/stack-up --config PATH --print-paths` | where the logs, history and backups are |

`--check` runs the config's `probe` commands without repairing anything; read the probes before running it.

## Reading a run

- The closing line decides, the one just above `Stop it with` and `Run log` in a run that reached its summary: `Open` (exit 0), `Degraded:` (exit 3), `Partial:` (exit 1). A run that stopped early ends instead with `STOPPED` and the reason (exit 1), then `Run log`, and, when something this stack started is still recorded (by this run or an earlier one) or this run ran a compose up, the entries still recorded, a line that compose services may still be running, or both, and a `Stop it with` line; what it started keeps running until that command runs. An interrupted start ends with `INTERRUPTED` and its stop command (exit 129, 130 or 143), and a start refused because another run of the same stack holds the lock exits 4 with no closing line. `Open <url>` means the smoke check proved that address answers; `Open (not checked): <url>` means the smoke check did not fetch that address (none is configured, or it checks another one); `Open: everything that started is running` means the smoke check was skipped (the line says why) or neither `smoke_url` nor `open_url` is set, and it counts the selected entries that were off or known defects; `Open: nothing was selected, so nothing started` and `Open: this run started nothing (...)` mean this run started nothing, which is not the same as a stack that is up.
- Each failure prints `WHO` and `WHAT`, and `LOG` when there is a log to read. When an entry's own command failed, WHO is the owner from the first matching `[signature]`; a failure found before the command runs, or by a check, names a fixed owner. Explain WHO in plain words and point at the LOG file when there is one.
- The run log (`logs/run-*.log`) has one line per event and ends with a `VERDICT` line. `history.tsv` has one row per start, `--stop` and `--clean`, with the exceptions `docs/ARCHITECTURE.md` lists; `--plan` and `--check` write none.
- A port "held by PID N (name), which this stack did not start" means another program, or another stack, is on that port. Do not stop it for the person; tell them what it is. A port "held by NAME (PID N), which this stack started in an earlier run" is freed by this stack's `--stop`; ask the person before running it.

## Adapting a config

1. One section per thing: `[service]` for long-running processes (`start`, `port`, `ready`), `[job]` for one-off setup (`run`, `run_if`), `[compose]` for containers, `[env]` for secrets (named in `env_from`; a `[compose]` entry takes no `env`, `env_file` or `env_from`).
2. Put things in stages and add `depends_on` where order matters inside a stage.
3. Give each service a real readiness probe: `http URL 200` for web services, `port` for anything that listens, `alive N` only for workers without a port.
4. Add `[check]`s for settings people forget. A `repair` needs a `target` (copied first) or a `backup` command, and should write a new copy and move it into place.
5. Add `[signature]`s for known failures, most specific first, each with an `owner` and a one-line `explain`.
6. Iterate with `--plan` until it reads right. Only then ask the person before running it.

The full reference is `docs/CONFIG.md`; the design and its invariants are in `docs/ARCHITECTURE.md`; platform porting is in `docs/ADAPT.md`.

## Never

- Never start, stop or clean a stack without the person asking: no plain run, `--stop` or `--clean` on your own initiative.
- Never run `--stop`, `--clean` or `--print-paths` for a stack without the `--config` and `--root` it was started with; the printed `Stop it with` line carries both (the `--root` only when the run was given one).
- Never add `pkill`, `killall`, code that signals a parent process, a signal outside the three helpers `su_alive`, `su_signal_group` and `su_signal_launch`, or any command that removes containers, volumes or images.
- Never edit `lib/`; it is pinned by `lib/MANIFEST.sha256`.
- Never put secrets in `stack.conf`, on a command line or in output; use an `[env]` provider and `env_from`.
- Never use `sudo` or install software for the person.
- Never report a test or a run as passing without running it and reading its last line.
