# Architecture: the reference design

This is the design stack-up implements. I wrote it down so it can be carried to another language, shell or operating system: the rules under "Invariants" are the part worth keeping in any port; the rest is one way to meet them.

## The problem it solves

A local stack is a set of processes and containers that have to start in the right order, with the right settings, on ports nothing else is using. The usual failure modes are quiet: a service "starts" but is not listening, a port answers but belongs to some other program, a setting is missing and the error shows up three services later, and the stop script kills whatever happens to be on port 3000. stack-up's answer is to declare everything, prove everything, record everything, and signal only what it can prove it started; the one thing it acts on by name is its compose project, whose declared services `--stop`, and a start for an option that is off with `when_off = stop`, ask compose to stop (invariant 4).

## Flow

```
stack-up [flags]
  |
  +-- parse flags ................................ bad flag -> exit 2
  |      --help / --version / --print-schema: print, exit 0 (no config is read)
  +-- read + validate stack.conf (file:line) ...... invalid  -> exit 2
  |
  +-- --print-config / --print-paths / --plan / --check (--check runs the probes)
  |      print and exit; no folder, no lock, no log        (--plan: 0, or 1 on a port clash)
  |
  +-- --stop with no state folder and no [compose] entry, or --clean with no state folder:
  |      say there is nothing to do, exit 0
  +-- create state + log folders; take the run lock ...... held by another run -> exit 4
  |      a lockf without the descriptor form -> stop, nothing started (exit 1)
  +-- install traps (INT 130, TERM 143, HUP 129, EXIT); keep the machine awake
  |
  +-- --stop -------------------------------------------------------------+
  |                                                                       |
  +-- Configuration: options from --with/--without, a question, or the default
  +-- Selection: menu, --select or default_select; add dependencies (noted)
  +-- Plan: order inside each stage; two selected entries on one port -> stop (exit 1)
  +-- Preflight, collected: commands, files, folders, the port of each service to start
  |      port held by anything but that service's own recorded group -> stop, nothing signalled (exit 1)
  +-- Options that are off with when_off = stop: stop their recorded services,
  |      and compose -p NAME stop their [compose] services if engine_check answers
  +-- Container engine (only if a [compose] entry is selected): check, start, deadline
  |
  +-- for each stage in [stack] stages:
  |      for each selected entry, dependencies first:
  |        option off .................. skip
  |        known defect ................ DEFECT, not counted
  |        dependency or check unmet ... fails by its on_fail, not started
  |        [env]     run, keep KEY=VALUE in memory for its consumers
  |        [job]     run_if?  run under a deadline in its own group; exit + markers
  |        [compose] compose -p NAME up -d; wait for health
  |        [service] launch in its own group with a launch token; record it;
  |                  ready = probe passes AND leader alive (AND, for a port or http probe with a port, a listener in the group),
  |                  before the deadline; on failure: stop the group, heal once, and start it again if the heal passed
  |      checks of this stage: verify -> back up -> repair -> verify
  |
  +-- Verification: smoke check, one fetch per attempt, until a deadline;
  |      then every service counted ready: group gone -> failed, or degraded with on_fail = warn
  +-- Summary -> closing line -> VERDICT + history row -> exit 0 open | 1 partial | 3 degraded
  |
  +-- STOP (from --stop) --------------------------------------------------+
         read run/launched.tsv, newest first
         for each record: is its group gone? (pgrep -g and kill -0 -- -PGID agree)
            gone      -> drop the record
            undecided -> do not signal; keep record and token; report it (exit 1)
            running   -> members still hold its launch token?
               yes -> TERM the group; wait stop_timeout; still there and still ours -> KILL
               no  -> do not signal; report it (exit 1)
         every token under run/tokens: a holder outside its recorded group
            (or of a token with no record left) -> name it, do not signal it,
            keep the token (exit 1)
         compose -p NAME stop SERVICES, for each [compose] entry (never down)
         verify: groups gone; project containers running = 0; every recorded or
                 declared port named if something still holds it
         "Everything this stack recorded is down. Safe to power off the machine."
         exit 0 | leftovers, exit 1
```

## Stages and entries

- A stage is a name in `[stack] stages`. Entries run stage by stage, in dependency order inside a stage, file order breaking ties. A dependency may sit in the same or an earlier stage, never a later one; the validator rejects the rest, including cycles.
- `parallel_stages` changes one thing: every service in the stage is launched first, then each is waited for; a service whose dependency is a service of the same stage is launched once that dependency is ready.
- Entries are pulled in by selection (menu, `--select`, `default_select`), by `always = yes`, or because a selected entry depends on them (`depends_on`, `env_from`). Every entry added for a dependency is announced.
- A required `[check]` runs at the end of its stage, so the validator requires it to sit in an earlier stage than a dependent it names.
- `on_fail` classifies a failure: `abort` stops the run (exit 1), `count` makes it partial (exit 1 at the end), `warn` makes it degraded (exit 3 at the end). Defaults: `count` for services, `abort` for everything else.

## Invariants

These are the rules a port must keep. Where a test enforces one, that test is named in brackets.

1. **Only signal what you started.** Every launch runs in a new process group (bash `set -m`) with the launch token, a small file under the state folder, open on file descriptor 19. The launch table records name, pid, pgid, token and port. A launched group is signalled only while one of its members holds that token, with two cases at the moment of launch: a group whose launch cannot be written to the launch table is stopped at once, and only while the kernel still has the group whose ID is the new PID, because its token may not be open yet (a launch that already ended is not signalled, and a process it left behind that still holds the token is named); and a launch that could not be given its own group is sent TERM by its PID while that PID still answers `kill -0`; a group id that the system reused for another program cannot pass, because that program does not have the file open. No code signals a parent process, runs `ps`, or picks what to signal by a name or a pattern. The cost of this rule: a process that leaves the group is outside every signal. While it still holds its token, the run and `--stop` name it by that token and leave it for the person to stop (`--stop` keeps the token and exits 1); one that also closes its inherited files cannot be found at all. It is never guessed at. A group counts as gone only when `pgrep -g` lists nothing and the kernel also has no such group (`kill -0 -- -PGID`); when the two disagree for more than about a second, or pgrep fails, the group is "could not be checked": it is not signalled, its record and token are kept, and `--stop` exits 1. A launch is proven to lead its own group the same way, by asking the kernel for a group whose ID is the new PID. The shared library's keep-awake helper is not a launch and is proven another way: as a run ends it gets TERM only while `pgrep -P "$$" -x caffeinate` still lists its saved PID, that is while it is still a child of the engine's own shell, where that child's process name is `caffeinate`, so a PID the system handed to another program after the helper ended is left alone. The library also runs commands under a deadline, each in its own process group, among them jobs, builds, providers, prechecks, `run_if` and known-defect probes, `ready = cmd` and check probes, backups and repairs, heals, report commands and compose calls; when the deadline passes, or the run exits while one is running, it sends that group TERM only while the group's leader still answers `kill -0`, waits a short grace period while the group exists, and then sends KILL only if the group still exists. An interrupted `--check` stops its probe the same way. The library also reads a child's `$PPID` to learn the calling shell's own PID. [unit-process.sh cases a, e, l, m, n, o, r, r2, r4 and r5; unit-static.sh with its probes; e2e-demo.sh decoy and foreign-holder cases; docs-cli.sh keep-awake release cases; unit-exit.sh --check interruption case; the deadline's TERM and KILL are tested in the shared library's own suite, which is not part of this repository]
2. **Ready is bound to the launch.** A service is ready only when the launched leader is alive on every poll, its probe passes, and (for a port or an http probe with a port) a listener on the port is a member of the launched group, all before `ready_timeout`. A process that dies fails at once. [unit-process.sh cases b and c; unit-exit.sh]
3. **Foreign holders are named, never evicted.** The port of each service a run is about to start, held by anything but that service's own recorded group, stops the run in preflight and nothing is signalled; the holder is named by its PID and command when this account can see them, and by its entry when this stack recorded it. [e2e-demo.sh; unit-process.sh]
4. **No machine-wide destruction.** Compose calls always carry `-p <name>` and every `-f` file; `--stop` uses `stop`, never `down`; there is no destroy command. Printed cleanup commands are scoped by the project label and quoted for the shell. [unit-compose.sh, including a project folder with a space in its path; unit-validate.sh; unit-static.sh docs rules]
5. **Backup first, verify after.** A repair runs only after its `target` was copied (file 600 in a folder 700), when that file exists, and after its `backup` command succeeded, when it has one; the check is verified again afterwards. When a target was copied, the audit says whether a failed repair left it unchanged, measured against that copy. [unit-contract.sh]
6. **Secrets stay in the child.** Provider values, `env` and `env_file` are exported only inside the forked child, after the fork and before `exec`. They never enter the engine's environment or any command line. The run log names a provider's keys as `KEY=<set>`, never their values; `env` and `env_file` keys are not logged. [unit-process.sh case f; unit-static.sh dynamic-export rule]
7. **Honest endings.** The exit status and the closing line come from the counters: any counted failure is `Partial` (1), else any warn failure or failed smoke check is `Degraded` (3), else `Open` (0). A service that passed its probe but whose group is gone at the end of the run is a counted failure, or degraded with `on_fail = warn`. `Open <url>` is printed only when the smoke check proved that very address answers; any other `open_url` is printed as `Open (not checked): <url>` when the smoke check passed or no `smoke_url` is set, a skipped smoke check prints no URL, an `Open` line without a URL counts the selected entries that were off or known defects, and a run in which every selected entry was off or a known defect says `this run started nothing`. A run that ends without a verdict is recorded as failed by the exit trap, and never exits 0. [unit-exit.sh, including its skipped-smoke, unchecked-URL, other-URL, nothing-ran, some-skipped, died-after-ready (with `on_fail = count` and `warn`) and no-verdict cases; unit-process.sh cases u, u4, u7, u8 and u9, for entries whose env_file, needs or precheck fail before they start, and u5 and u6 for the env_file and ${PORT} paths that pass]
8. **Nothing before validation.** Flags and the whole config are checked before any folder, lock or log is created; `--plan` never creates any. [unit-validate.sh; e2e-demo.sh]
9. **One run at a time per stack.** The run lock is held for the whole run; a second run exits 4. [unit-exit.sh]
10. **Everything from config.** No project path, port or service name is built into the engine; the default state folder and the container engine commands are defaults the config can change. [paths: unit-static.sh machine-paths rule; ports and service names are held by review, not by a test]

## Records

| record | format | written by |
|---|---|---|
| run log | `YYYY-MM-DD HH:MM:SS  TAG     message`, tag padded to 7. Tags: PHASE SECTION OK WARN SKIP INFO FAIL DEFECT FAULT FAILED ABORT ASK VERDICT | every step; one file per run |
| FAULT line | `owner label \| explanation \| log path or "no log"` | every failure with an owner |
| VERDICT line | `outcome exit=N detail`, with the same detail as the history row | the summary, the exit trap, an abort, a signal, `--stop` and `--clean` |
| history row | `time TAB mode TAB outcome TAB exit=N version=V detail`, where detail is the VERDICT fields for a start, `stopped=N` (with ` left=[...]`) for `--stop` and `removed=N` (with ` of=M`) for `--clean`, or a short reason when a run stopped early or was busy | one per start once its state folders are ready, and per `--stop` or `--clean` on a stack that has run here (or, for `--stop`, whose config has a compose entry) |
| launch table | `name\|kind\|pid\|pgid\|token\|port\|log` | each launch; rewritten when a group is stopped |
| repair audit | `=== time check NAME`, `repair:`, `backup:` or `backup command:`, `output:`, `result:`, `re-verify:` | each repair attempt |
| heal ledger | `time TAB heal TAB entry TAB exit=N` and `recovered` or `not recovered` | each heal attempt |

The run log and the history file use the line formats of the shared `lib/`, which this repository vendors byte for byte and pins with `lib/MANIFEST.sha256`; the sibling tool weekly-update writes the same formats.

### What a run leaves behind

Everything lives under `${XDG_STATE_HOME:-$HOME/.local/state}/stack-up/<name>/` unless the config says otherwise (`stack-up --print-paths` shows the exact paths). An `XDG_STATE_HOME` that is not an absolute path is ignored, as the XDG spec says, and so is a relative `HOME`. Two configs with the same `[stack] name` share that folder, and each one's `--stop` stops the other's services, so give each stack on a machine its own name:

| file | contents |
|---|---|
| `logs/run-<time>-<pid>.log` | one line per event: `date  TAG     message`, ending with a `VERDICT` record |
| `logs/<entry>.log` | each entry's own output, restarted on each start |
| `logs/<entry>.build.log` | a service's build output, appended, one `--- run <id>  <command> ---` line per run |
| `history.tsv` | one row per start once its state folders are ready, and per `--stop` or `--clean` on a stack that has run here (or, for `--stop`, whose config has a compose entry); `--plan` and `--check` write none. Each row: time, mode, outcome, then `exit=N version=V` and the mode's own fields: `selected=[..] failed=[..] degraded=[..] defects=[..]` for a start, plus `smoke=failed` when the smoke check failed (`selected` lists every selected entry, including added dependencies and an entry whose option was off; the run log names that entry as off), a short reason instead when a run stopped early, was interrupted, or found another run holding the lock, `stopped=N` for `--stop` (`stopped=N left=[..]` when something is left), `removed=N` for `--clean` (`removed=N of=M` when a file could not be deleted) |
| `run/launched.tsv` | `name\|kind\|pid\|pgid\|token\|port\|log` for each service this stack launched and still records |
| `run/tokens/` | the launch token files of those launches |
| `run/launched-<run id>.tsv` | an emptied launch table, set aside by a `--stop` that left nothing running; `--clean` deletes these |
| `run/lock` | the file a run locks while it lasts, so a second run of the same stack exits 4 |
| `run/smoke.body` | the body of the last smoke check response |
| `repair.log` | every repair: the command, its output, where the original was kept, and the re-check |
| `backups/` | originals copied before a repair (folder 700, files 600) |
| `heals.tsv` | every heal attempt and its outcome |
| `logs/heal-<name>.log` | each heal's output, appended |

## Decision points

| decision | chosen | why |
|---|---|---|
| config format | sectioned `key = value`, parsed in bash | no parser to install on a stock Mac; line-numbered errors; values keep `\|`, `=` and quotes |
| process identity | process group plus an inherited launch token | the group lets one signal reach the whole tree; the token proves the group is still ours without `ps` start times, which need a privileged tool on some systems and have one-second resolution |
| readiness | deadline in seconds, liveness each poll, and for a port or http probe with a port, a listener in the group | an attempt count hides slow polls; a listener check without group membership accepts another program |
| foreign port holder | refuse and name it | the only safe default; evicting belongs to the person who owns that program |
| stop | recorded groups, then `compose stop` | a stop driven by ports or process names misses unbound services and hits other people's programs; compose is the exception, asked by project name, so containers started by hand under that name stop too |
| destruction | none run; `--print-paths` prints a project-scoped recipe to run by hand | a destroy step that runs itself is the easiest way to delete data that belongs to other projects on the same machine |
| discovery | manifest only | what runs is exactly what the file names; a scaffold is listed under "Extend this" |
| failure owners | ordered signatures from config, five built-in owners | the report should say who acts, and that knowledge belongs to the team, not the engine |

## Where each part lives

| file | role |
|---|---|
| `bin/stack-up` | the engine: flags, schema, validation, selection, launch, readiness, checks, stop, records |
| `lib/conf.sh` | the `key = value` reader and validator |
| `lib/report.sh`, `lib/term.sh` | run log, screen lines, history rows, verdicts |
| `lib/lifecycle.sh` | traps, run lock, keep-awake, deadlines in their own process group |
| `lib/prompt.sh` | the terminal test and the answer device used by the questions |
| `lib/classify.sh` | the ordered signature matcher |
| `lib/gate.sh`, `lib/testing.sh` | the static gate and the test helpers |
| `lib/util.sh` | shared helpers: word lists, trimming, number checks |
| `lib/MANIFEST.sha256` | the checksums that pin `lib/` byte for byte |
| `examples/demo/` | the demo stack |
| `tests/` | unit, end-to-end, static and docs tests; `tests/run-all.sh` runs them all |
