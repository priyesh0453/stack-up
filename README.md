# stack-up

One command brings a local development stack up in order, proves each piece is really up, names who should fix what failed, and on `--stop` signals only the processes it launched, then asks compose to stop the services its config names. Everything your stack runs is declared in one plain-text file, `stack.conf`; the tool itself is a bash script plus a small shared library under `lib/`, with no dependencies beyond what a current Mac ships.

## The 30-second pitch

Bringing a multi-service project up usually means a page of notes: start the containers, wait, seed something, fix the setting that is always missing, start six services, find out which one died and why. I wrote stack-up to turn that page into a config file and run it the same way every time.

It starts entries in the order you declare, and a service counts as up only when its launched process is still alive and its readiness probe passes before a deadline. A failure's log is matched against patterns you declare, so the report names who should act and why, and a check that finds a setting missing repairs it, backup first.

The closing line is honest: `Open <url>` only after the smoke check proved that address answers, `Partial` or `Degraded` when something failed, `STOPPED` with the reason when the run stopped early.

The technical core: every service launch gets its own process group and a launch token; a port probe counts only a listener in that group; `--stop` signals a recorded group only while one of its processes still holds its token, then asks compose to stop the services its `[compose]` entries name under that project name. stack-up itself never signals a program it did not launch (the windows between a check and its signal are in [docs/LIMITATIONS.md](docs/LIMITATIONS.md)).

The demo stack in `examples/demo`, built from bash, nc and other stock tools, lets you watch all of this in a minute without installing anything.

## A reference design, not a product

I wrote stack-up to be copied and changed. It encodes a way of bringing a stack up (declare, order, prove, attribute, record, stop by ownership) more than a fixed tool.

Expect to:

- replace the demo's entries with your own ([docs/CONFIG.md](docs/CONFIG.md) has every key);
- put your team's "when the log says X, the cause is Y" knowledge into `[signature]` sections;
- on another platform, swap the handful of macOS calls ([docs/ADAPT.md](docs/ADAPT.md) lists each one, and ends with a prompt for adapting a config with a coding assistant).

The design itself, including the rules that must survive any adaptation, is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Who this is for

- **Developers** who start the same services every morning and want one command, one log and a straight answer about what failed.
- **Teams and platform people** who want the "how to run it locally" page to be executable and testable instead of a wiki page that drifts. `AGENTS.md` and `skills/stack-up/` carry the instructions for coding agents.
- **Non-developers** who need a product running locally for a demo, a design review or support work: one command, one closing line, and when something fails the report says who to ask. The FAQ lists the three commands you need.

## What it never does

- It never signals a process it did not start, never signals a parent process, and never picks what to signal by a name or a pattern. A program already on one of your ports is named and left alone.
- It never asks compose or the container engine to remove a container, volume or image: no `down`, `rm` or `prune`. `--stop` asks compose only to `stop` the services its `[compose]` entries name, under the project name.
- It never repairs a setting without keeping the original first, and never repairs at all when you pass `--no-repair`.
- It never puts a secret on a command line or into its own environment: `[env]` values reach only the entries and heals that name the provider, and the logs show `KEY=<set>`.
- It never uses `sudo`, installs software or changes system settings, except what the commands in your config do.
- It never sends a probe through a proxy: every `http` readiness probe and the smoke check run `curl -q --noproxy '*'`, so `http_proxy`, `ALL_PROXY` and `~/.curlrc` can neither answer for this machine nor fail it.
- It never reports more than its probes proved: the closing line and the exit status come from the checks, the smoke test and a last look that every service counted ready is still running, and `--stop` calls a group stopped only once it is proven gone.

## Quickstart

Clone it, then run the five commands below from the repository folder:

```sh
git clone https://github.com/priyesh0453/stack-up.git
cd stack-up
```

<!-- quickstart:begin -->
```sh
bin/stack-up --config examples/demo/stack.conf --plan
bin/stack-up --config examples/demo/stack.conf --yes
curl -s http://127.0.0.1:18081/
curl -s http://127.0.0.1:18082/
bin/stack-up --config examples/demo/stack.conf --stop
```
<!-- quickstart:end -->

On a Mac that has never used git, the clone offers to install Apple's command line tools; "Code", then "Download ZIP" on the GitHub page skips that. `tests/e2e-demo.sh` runs exactly these five lines, with free ports and a copy of the demo config swapped in.

What you should see:

- `--plan` prints the stages, the setup job, the settings check with its backup and both services with their probes, and writes nothing.
- The run seeds a settings file with one key missing, backs it up and repairs it, starts hello-api and docs-site, each proven listening from its own process group, passes the smoke check, and closes with `Open http://127.0.0.1:18081/health`, the stop command and the run log path.
- The two `curl` lines answer `hello from the demo stack` (the value the repair added) and a one-page HTML file.
- `--stop` stops both process groups and ends with "Everything this stack recorded is down. Safe to power off the machine."
- On a work network that exports `http_proxy` or `ALL_PROXY`, add `--noproxy '*'` to the two `curl` lines, or they ask the proxy instead of this machine; the tool's own probes already do.

The full capture is in `docs/sample-output.txt`. Run without `--yes` to get the questions, or add `--select all --with ticker` to see a portless worker and a known defect being skipped.

To run it by name from any folder (optional, no sudo): `./install.sh` makes a link in `~/.local/bin` to this folder.

Put `~/.local/bin` on your PATH once if it says it is not there yet: `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zprofile` (`~/.bash_profile` for bash; `./install.sh` prints the right one), then open a new Terminal window. Until then, keep using `bin/stack-up` from the repository folder.

| Command | What it does |
|---|---|
| `./install.sh --copy` | makes a copy in `~/.local/share/stack-up` and points the `~/.local/bin` link at that copy instead of this folder, so it keeps working after this folder moves |
| `./install.sh --prefix DIR` | installs under `DIR` instead of `~/.local` |
| `./install.sh --dry-run` | prints what would change and changes nothing |

## How it works

A run goes through fixed steps, and nothing is written until the config has been read and validated:

1. **Read and validate** `stack.conf`; any problem names the file (and the line, where there is one) and exits 2.
2. **Plan** the options, the selection, the dependencies and the order inside each stage; two selected services on one port stop the run here.
3. **Preflight**, in one report: missing commands, files, folders and held ports. A port held by anything but that service's own earlier copy is a hard stop, and nothing is signalled.
4. **Stages**, in the order of `[stack] stages`:
   - `[env]` providers print `KEY=VALUE` lines, kept in memory for the entries that name them;
   - `[job]`s run under a deadline in their own process group;
   - `[compose]` entries run `compose -p <name> up -d` and wait for health;
   - `[service]`s launch in their own process group, are recorded, and must pass their readiness probe before the deadline while staying alive;
   - a stage's `[check]`s run at its end: verify, back up, repair, verify again.
5. **Verification**: the smoke check fetches `smoke_url` until it answers or its deadline passes; then every service counted ready is checked once more, and a gone process group is a failure.
6. **Summary**: counts per stage, known defects with an owner, the closing line, a VERDICT record in the run log and one row in the history file.

`--stop` reads the launch table, then:

- proves each recorded group is still this stack's own and stops it: TERM, a grace period, then KILL only if still proven;
- names, without signalling it, a launched process that left its group but still holds its launch token;
- asks compose to stop the project's `[compose]` services;
- verifies that no recorded group or held launch token is left.

The flow as a diagram, the invariants with the test that pins each one, and the files a run leaves behind are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

### Command-line flags

`stack-up --help` prints the same list, and `tests/docs-cli.sh` fails when the two disagree. The exit statuses are in [docs/CONFIG.md](docs/CONFIG.md#exit-status).

| flag | what it does |
|---|---|
| `--config FILE` | the config file (default: `./stack.conf`) |
| `--root DIR` | base folder for relative paths; overrides `[stack] root` (a run given `--root` needs the same `--root` on `--stop`, `--clean` and `--print-paths`) |
| `--plan` | print what would run, in order, then exit; writes nothing |
| `--dry-run` | same as `--plan` |
| `--check` | run the `[check]` probes without repairing, then exit |
| `--stop` | stop the process groups this stack recorded, and ask compose to stop its [compose] services |
| `--clean` | delete this stack's rotated launch tables, unused launch tokens and, with `keep_runs` above 0, older run logs (asks first) |
| `--print-config` | print the parsed config as `kind\|name\|key\|value` rows |
| `--print-schema` | print every config key with its type and default |
| `--print-paths` | print where this stack keeps state, and cleanup commands to run by hand |
| `--select SPEC` | pick entries without a menu: `essential`, `recommended`, `all`, `none`, numbers such as `2` or `1-3`, names, `group:NAME` |
| `--with OPTION` | turn an `[option]` on without asking (repeatable) |
| `--without OPTION` | turn an `[option]` off without asking (repeatable) |
| `--yes` | ask nothing: every question takes its default, and `--clean` proceeds |
| `--no-repair` | report unmet checks without repairing them |
| `--version` | print the version |
| `-h`, `--help` | print this help |

## Config reference

A config is a set of sections. The smallest useful one, a service with a readiness probe and one known failure:

```ini
[stack]
name = shop
smoke_url = http://127.0.0.1:8001/health

[service api-gateway]
port = 8001
start = exec ./run.sh
ready = http http://127.0.0.1:8001/health 200

[signature port-in-use]
match = [Aa]ddress already in use
owner = this-machine
explain = another program already listens on this port
```

The section kinds:

| kind | what it declares |
|---|---|
| `[stack]` | name, stages, menus, smoke check, container engine |
| `[service NAME]` | a long-running process: how to start it, its port, how to know it is ready |
| `[job NAME]` | a command run once per run under a deadline; `run_if` skips it when its work is done |
| `[compose NAME]` | services from your compose files: `up -d` to start, `stop` to stop |
| `[env NAME]` | a command that prints `KEY=VALUE` secrets for the entries naming it in `env_from` |
| `[check NAME]` | a setting that must hold, with an optional backup-first repair |
| `[option NAME]` | a yes/no question; `--with` and `--without` answer it from the command line |
| `[signature ID]` | a log pattern and the owner it points to |
| `[heal NAME]` | a one-time fix to try when a service fails in a known way |
| `[owner ID]` | the label printed for an owner id |

Every key with its type and default, a larger example with a compose entry and a seeding job, the placeholders, the readiness forms, the selection words, the owners and the exit statuses are in [docs/CONFIG.md](docs/CONFIG.md). Its tables are tested against `stack-up --print-schema`, so they cannot drift.

## Cross-platform notes

I have tested stack-up on macOS with the stock bash 3.2, on Apple Silicon only; nothing in the code depends on the processor, but I have not run it on an Intel Mac. `lsof` lives in `/usr/sbin`, which Terminal puts on PATH; a cron job or an editor with a shorter PATH makes `--plan` report `lsof` as missing, so add `/usr/sbin` there.

I have not tested Linux or Windows: the platform-specific calls are few (`lsof`, `pgrep -g`, `kill -SIG -- -PGID`, `lockf`, `caffeinate` and `nc`), and [docs/ADAPT.md](docs/ADAPT.md) section 3 gives each one's Linux and Windows equivalent.

## Known limitations

- Every start takes its run lock with the `lockf` form current macOS documents, which locks an open file descriptor; an older release with only the `lockf file command` form stops the run with exit status 1, and says so, before it starts or stops anything.
- Every signal follows a check, and a window of well under a second remains between the two, in which the checked process could end and the system could reuse its number.
- `--stop` can act only on what it recorded: a launched process that leaves its group is named, never signalled, while it still holds its launch token, and one that also closes its inherited files, or that a job, build, provider, check or heal left running, cannot be seen at all. Start long-running processes as `[service]` entries.
- `ready = http URL` without a `port` key accepts any program that answers the URL, and `cmd` and `alive N` probes prove only what they check; only a `port` probe, or an `http` probe with `port`, ties the listener to the launched group.
- Nothing watches the stack after the run: a service that exits after the run is over is not reported until the next run starts it again.

The full list, with what each one means for you and how I tested it, is in [docs/LIMITATIONS.md](docs/LIMITATIONS.md).

## Extend this

Ideas that fit the design, in rough order of payoff; none of them is in v0.1:

- a `--discover` scaffold that drafts `[service]` sections from your source tree;
- Linux as a first-class platform: `ss`, `systemd-inhibit`, a tested `flock` fallback and Linux CI;
- a PowerShell port for Windows;
- signature packs for common runtimes;
- check probes for other settings stores, behind the same verify, back up, repair, verify contract;
- a JSON-lines record beside the text run log;
- a project-scoped destroy command behind an explicit flag and a typed confirmation.

Add a config key with one row in `su_schema_rows` and the matching row in `docs/CONFIG.md`; add a flag to `su_flag_table`, `su_parse_args` and the flag table above. `tests/docs-cli.sh` fails until they agree, `tests/unit-static.sh` on a signal outside `su_signal_group` and its two helpers, and `tests/unit-manifest.sh` on any change under `lib/`, which is shared with a sibling tool. The rules any change must keep, each with the test that pins it, are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); changing behaviour and porting are in [docs/ADAPT.md](docs/ADAPT.md).

For a coding agent working in a copy of this repository, the instructions are in `AGENTS.md`, and the skill is `skills/stack-up/SKILL.md`, a plain folder you can copy into any agent that reads skills.

## FAQ

**Not a developer? What do you actually need to type?** Three commands, in a Terminal window opened in the folder that holds the stack's `stack.conf`: `stack-up` starts it (press Return to take the defaults), `stack-up --stop` stops it, and `stack-up --plan` shows what would happen first. Without an install, type the script's path instead, for example `~/stack-up/bin/stack-up --stop`; a start prints the exact stop command.

**What does the closing line mean?** `Open` with an address means it worked. `Partial` or `Degraded` means something did not, and the WHO and WHAT lines above it say who should look. `STOPPED` means the run stopped early, and what it started keeps running until you run `stack-up --stop`.

**Is it safe to run?** stack-up itself starts and checks only what the config declares, and signals only processes it launched. The commands inside a `stack.conf` run as you, so read a config before running it, the same as any script.

**What if a port is already in use?** The run stops before anything starts, names the holder (its PID and command name when your account can see them, or the entry of this stack that holds it) and leaves it alone. Then stop that program yourself, change the port in the config, or, for a holder this stack started in an earlier run, run `stack-up --stop`.

**What if you close the terminal or press Ctrl-C?** The run stops with exit status 130 (or 129 or 143) and records why. Services it already started keep running and are recorded, so the stop command it printed stops them (`stack-up --stop` with the same `--config`, plus the `--root` you gave, if any); a job in the middle of running is stopped with the run.

**Why bash 3.2 and a custom config format instead of YAML?** A stock Mac has bash 3.2, so I wanted a script that needs nothing installed first. The format is small enough to parse in bash with line-numbered errors, and values can hold shell commands with `|`, `=` and quotes untouched.

**How was it built?** I drafted much of the code with AI assistance. The design, the safety rules, the review and the test runs are mine. It follows a private tool I use at work, rewritten from scratch.

## Uninstall

1. Stop anything still running: `stack-up --config <your config> --stop` (without an install, run `bin/stack-up` from the repository folder instead of `stack-up`, here and in step 2; if you started the stack with `--root`, add the same `--root` here and in step 2).
2. See what it keeps: `stack-up --config <your config> --print-paths`. Its last line is the exact `rm -r --` command for that stack's state folder (logs, history and backups), if you want it gone, and above it are the project-scoped compose removal commands to run by hand; in a `state_dir` shared with other files, delete only stack-up's files.
3. Remove the installed command, from the repository folder: `./uninstall.sh` (`./uninstall.sh --prefix DIR` if you installed with one; `--dry-run` shows what would be removed first). It removes only the link `install.sh` made and, for a `--copy` install, the copy (left alone when you added files beside it); then delete the cloned folder.

## License

MIT. See [LICENSE](LICENSE).
