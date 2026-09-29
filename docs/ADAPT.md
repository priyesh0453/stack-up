# Adapting stack-up

stack-up is a reference design. This page covers the three kinds of adaptation people actually do: pointing it at your own stack, changing how it behaves, and porting it to another platform. At the end is a prompt a non-developer can paste into an AI assistant to adapt a config with them.

## 1. Point it at your stack (no code changes)

1. Copy `examples/demo/stack.conf` next to your project, or start from the small example in the README's "Config reference".
2. Set `[stack] name` (it names the default state folder and the compose project) and `stages` (the order things start in).
3. Add one section per thing to run:
   - long-running processes: `[service NAME]` with `start`, `port` and `ready`;
   - one-off setup: `[job NAME]` with `run`, and `run_if` so it only runs when needed;
   - containers from your compose files: `[compose NAME]` with `services`, plus `[stack] compose_files`;
   - secrets: an `[env NAME]` provider whose command prints `KEY=VALUE` lines, named in `env_from` by the entries that need them. A `[compose]` entry takes no `env`, `env_file` or `env_from`; set those values where compose itself reads them.
4. Add a `[check]` for each setting that people forget, with a `probe` and, if you want it fixed automatically, a `repair` plus a `target` or `backup`. Write the repair so it writes a new copy and moves it into place (see `examples/demo/add-greeting.sh`); then a failed repair leaves the target as it was.
5. Add `[signature]` sections for the failures your team already knows, each with an `owner`.
6. Run `stack-up --config stack.conf --plan` until the plan reads right, then run it for real.

Useful while writing a config: `--print-config` (what was parsed), `--print-schema` (every key), `--check` (probes only) and `--select` (start a subset).

## 2. Change how it behaves

The engine is one bash file, `bin/stack-up`. Its functions are grouped under section comments: flags and schema at the top, then arguments, config access, the model and validation, owners and signatures, paths, selection, processes, the launch table, the child environment, the toolchain, readiness, outcomes, the entry runners, checks, the smoke check, state, the modes (`su_mode_up`, `su_mode_stop`, `su_mode_plan` and the rest) and main.

Rules for changes; each of the first five is backed by a test in `tests/`:

- Add a config key by adding one row to `su_schema_rows`; the validator, `--print-schema` and the `docs/CONFIG.md` test all follow from that row. Update `docs/CONFIG.md` and run `tests/docs-cli.sh`.
- Add a flag by adding it to `su_flag_table` and `su_parse_args`, and to the flag table in the README; `tests/docs-cli.sh` fails until all three agree.
- Keep every signal inside `su_signal_group` (and the two small helpers next to it); `tests/unit-static.sh` fails on a `kill` anywhere else, on any `pkill`, on a parent-process lookup, and on `ps`.
- Keep provider values inside `su_exec_child` and its two export helpers; the same test fails anywhere else on an `export`, `declare -x` or `typeset -x` whose name comes from a variable (`"$..."` or `$...`).
- Do not edit `lib/`. It is shared with the sibling tool and pinned by `lib/MANIFEST.sha256`; `tests/unit-manifest.sh` fails on any change. Work around a missing library feature in `bin/stack-up`, as `su_check_shapes` does for URLs and `KEY=VALUE` values, which the library's types cannot check without one process per value.
- Run everything with `tests/run-all.sh`, and `shellcheck -x bin/stack-up`.

## 3. Port it to another platform

The platform-specific calls are in these functions:

| function | macOS call | what it must do on the new platform |
|---|---|---|
| `su_launch` | `set -m` then `cmd &`, token open on fd 19 | start the process in a new process group (or job object) and pass it an inherited handle that proves who started it |
| `su_members` | `pgrep -g PGID`, confirmed with `kill -0 -- -PGID` | list the processes in that group, and tell "gone" from "could not be checked" |
| `su_group_is_ours` | `lsof -t -- TOKEN` | list the processes holding the token file open |
| `su_signal_group` | `kill -SIG -- -PGID` | signal the whole group (or stop the job object) |
| `su_listeners` | `lsof -nP -iTCP:PORT -sTCP:LISTEN -t` | list the processes listening on a TCP port |
| `su_port_answers` | `nc -z 127.0.0.1 PORT` | test whether anything accepts connections on the port |
| `su_describe_pid` | `lsof -nP -p PID -Fc` | print a process's command name |
| `su_token_strays` | `lsof -t -- TOKEN` | list the processes holding a launch token file open |
| `su_stop_strays` | `command -v lsof` | tell whether the launch tokens can be checked at all |
| `su_lan_note` | `lsof -nP -iTCP:PORT -sTCP:LISTEN` | list a port's listeners with the address each one is bound to |
| `su_collect_requires` | `lsof pgrep nc` for any selected service, `curl` for an http probe or a smoke check | name the commands a run needs on the new platform |
| `su_lock_tool_ok` | `lockf -s -t 0 9` | tell whether the lock tool can lock an open file descriptor |
| run lock (`lib/lifecycle.sh`) | `lockf` | `flock` on Linux (the library already falls back to it); a lock file opened exclusively on Windows |
| keep awake (`lib/lifecycle.sh`) | `caffeinate -i -w PID`, stopped as the run ends only while it is still a child of the engine's shell, where that child's process name is `caffeinate` | nothing in `lib/`: the library starts the helper only when `caffeinate` is on PATH and otherwise holds nothing. Set `keep_awake = off` and hold sleep off from outside for the length of the run, for example with `systemd-inhibit --what=idle` in front of the command on Linux; on Windows a PowerShell port calls `SetThreadExecutionState` |

The same map by need. I have tested only the macOS column; the other two are the map for a port, not a promise:

| need | macOS (tested) | Linux (untested) | Windows (untested) |
|---|---|---|---|
| shell | `/bin/bash` 3.2 | bash 4 or 5 runs the same script | Git Bash or WSL for the script as is; a PowerShell port for native use |
| who listens on a port | `lsof -nP -iTCP:PORT -sTCP:LISTEN -t` | the same with `lsof` installed, or `ss -ltnp 'sport = :PORT'` | `Get-NetTCPConnection -LocalPort PORT -State Listen` |
| members of a process group | `pgrep -g PGID` | `pgrep -g PGID` (procps) | job objects: `Start-Process -PassThru` and stop the job, not the process tree by name |
| signal a group | `kill -TERM -- -PGID` | the same | `Stop-Process -Id` on the recorded job's processes |
| run lock | `lockf` | `flock` (the library falls back to it) | a lock file opened with `FileShare.None` |
| keep awake | `caffeinate -i -w PID` | `systemd-inhibit --what=idle` | `powercfg /requests` to check, `SetThreadExecutionState` to hold |
| container engine | `engine_start = open -a Docker` in your config, if you want it started | `engine_start = systemctl --user start docker` or the system service | Docker Desktop, started by the user |
| `nc` (the engine's port check, and the demo) | BSD nc: `nc -z 127.0.0.1 PORT`, `nc -l 127.0.0.1 PORT` | OpenBSD nc (`netcat-openbsd`) takes the same flags | not available; use WSL |

Platform notes (I have not tested these):

- **Linux**: the script should run unchanged under bash 4 or 5 if `lsof`, `pgrep` (procps), an OpenBSD-style `nc` (`netcat-openbsd`) and `flock` are installed. Without `lsof`, rewrite `su_listeners` with `ss -ltnpH "sport = :$1"`, `su_group_is_ours` and `su_token_strays` by reading `/proc/PID/fd` links, `su_describe_pid` with `/proc/PID/comm` and `su_lan_note` with `ss`, and change the `lsof` check in `su_stop_strays` and the command list in `su_collect_requires`. The demo needs the same `nc`.
- **Windows**: run the script in WSL, or port the engine to PowerShell: `Start-Process -PassThru` gives real process ids, a job object replaces the process group, `Get-NetTCPConnection -State Listen` finds port owners, and `Stop-Process` stops only the recorded job's processes.

Keep the invariants in [ARCHITECTURE.md](ARCHITECTURE.md) whatever you change. They are the reason the tool signals only what it launched on a machine full of other people's programs; its actions by name, the compose `up` and `stop` of the services its config names, are invariant 4.

## 4. A prompt for any AI assistant

If you do not write code, you can still adapt stack-up with an AI assistant. Open a copy of this repository in an assistant that can read and run files, then paste this prompt and fill in the part in brackets:

```text
You are helping me adapt a copy of the stack-up repository to start my own
local development stack. Read README.md, AGENTS.md, docs/CONFIG.md and
skills/stack-up/SKILL.md first, and follow AGENTS.md exactly.

My stack: [describe each piece in plain words: what it is, how you start it
today, which port it uses, what it needs first, and which settings people
often forget].

Please:
1. Write a new stack.conf for my stack in a folder I choose. Do not edit
   bin/ or lib/.
2. Run only these commands until the plan looks right, and show me the
   output each time:
     bin/stack-up --config <my stack.conf> --print-config
     bin/stack-up --config <my stack.conf> --plan
3. Explain the plan to me in plain words: what starts, in what order, and
   what would be repaired.
4. Do not run the stack, --stop, --clean, install.sh or any command from
   inside the config until I say "run it".
5. Never add commands that kill programs by name, remove containers or
   volumes, use sudo, or print secrets.
```

When the plan reads right, say "run it". If something fails, paste the lines marked WHO, WHAT and LOG back to the assistant and ask what they mean.
