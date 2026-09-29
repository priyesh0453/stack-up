# Config reference

Everything stack-up does comes from one file, `stack.conf`. This page lists every key the validator accepts. The keys, types and defaults in the tables come from `stack-up --print-schema`, and `tests/docs-cli.sh` fails when a key is added, removed or retyped, or its default or its required or repeat mark changes, without this page following, so the page cannot drift from `--print-schema`; the meaning column may say more than the schema does. URL values (`smoke_url`, `open_url`, a service's `url`) are used as written: no placeholder is replaced in them.

## File format

```ini
# A comment: the first non-blank character of the line is #.
# [stack] is a section with no name; there is exactly one.
[stack]
name = demo

# A named section: [kind name].
[service hello-api]
start = exec bash hello-api.sh
```

- `key = value` splits at the first `=`; both sides are trimmed. The value is literal: quotes are kept, and `|`, `=` and `#` inside a value are ordinary characters. A `#` after a value is part of the value, not a comment.
- Blank lines are skipped, Windows line endings are accepted, and a last line without a newline is read.
- Names of services, jobs, compose entries, env providers, checks, options and heals are lowercase: `a-z`, `0-9` and `-`, starting with a letter or digit, up to 40 characters. Service, job, compose and env names share one namespace, because `depends_on` can point at any of them.
- A key marked "repeat" may appear more than once in its section; every other key appears at most once.
- The whole file is validated before anything runs. Problems are reported as `file:line: message` (`file: message` when no line applies, such as a missing `[stack]`), and the run stops with exit status 2. Some errors are found only after others are fixed, so fixing one can show more errors on the next run. A typo such as `dependson` is an error, never a silently dropped setting.
- `stack-up --print-config` prints the parsed file as `kind|name|key|value` rows, in file order.

## A small config

Containers from a compose file, a seeding job that runs once, a service that depends on it, and one known failure with its owner:

```ini
[stack]
name = shop
stages = infra prepare services
smoke_url = http://127.0.0.1:8001/health
compose_files = dev-env/compose.yaml

[compose datastores]
services = dev-sql dev-cache
stage = infra

[job provision]
stage = prepare
depends_on = datastores
run_if = ! test -f "$STACK_STATE/provisioned"
run = hooks/provision.sh && touch "$STACK_STATE/provisioned"

[service api-gateway]
tier = essential
dir = api-monorepo/gateway
depends_on = provision
port = 8001
start = exec ./run.sh
ready = http http://127.0.0.1:8001/health 200

[signature port-in-use]
match = [Aa]ddress already in use
owner = this-machine
explain = another program already listens on this port
```

## Placeholders and commands

Path values (`root`, `state_dir`, `log_dir`, `compose_files`, `dir`, `env_file`, `log`, `files`, `needs`, `target`) may use `${STACK_ROOT}`, `${STACK_STATE}` and `${HOME}`. The entry paths of a service that has a `port` (`dir`, `env_file`, `log`, `files`, `needs`) may also use `${PORT}`, which is that service's own port, and so may its `ready` value. `${PORT}` in any other path value, or in the `ready` value of a service without a port, is a validation error, because nothing else has a port. Placeholders are replaced literally, never evaluated; any other `${...}` in a path value, or in an `http` or `alive` ready value, is a validation error, and so are a `$` in a path value that does not start a `${...}` placeholder (write `${HOME}`, not `$HOME`) and an empty path value. A blank command value is a validation error (every key of type `command` except `engine_start`, where empty means stop with a hint), and so are a blank option `question`, `known_defect`, `needs_hint`, `precheck_hint`, `default_select`, signature `explain`, owner `label` or `advice`, an `open_url` or service `url` that is not an `http://` or `https://` URL, a blank `[compose]` `services` list, and a `[compose]` `services` list or `compose_files` value with `*`, `?` or `[` in it. An empty `ready` value is a validation error, `state_dir` cannot use `${STACK_STATE}`, the folder it names, and `root` cannot use it either, because root is resolved first. A relative path is relative to `STACK_ROOT`, except `root` itself, which is relative to the config file's folder (and a relative `--root` to the current folder).

Command values (`start`, `run`, `run_if`, `build`, `probe`, `repair`, `backup`, `precheck`, `known_defect_check`, `ready = cmd ...`, `report`, `engine_check`, `engine_start`, heal `run` and `when`) are shell text; in a `ready = cmd ...` value stack-up replaces `${PORT}` with the service's port first and leaves the other placeholders to bash, which expands them from the exported variables below; every other command is passed as written. stack-up runs each one with `bash -c` in a child process, in the entry's `dir` (default `STACK_ROOT`), with these variables exported:

| variable | value |
|---|---|
| `STACK_NAME` | `[stack] name` |
| `STACK_ROOT` | the root folder |
| `STACK_STATE` | this stack's state folder |
| `STACK_LOGS` | this stack's log folder |
| `STACK_COMPOSE` | the compose files, space-separated; a path that itself contains a space cannot be told apart here |
| `PORT` | the entry's `port`, when it has one (and `port_env` names one more variable with the same value) |

The config is therefore code: only run a `stack.conf` you have read, the same as any script.

Values from `[env]` providers, `env` and `env_file` are added only in the child that runs the entry. They never enter stack-up's own environment and never appear on a command line it builds. The run log names a provider's keys as `KEY=<set>`, never their values; `env` and `env_file` keys are not logged.

## Keys

Every entry kind ([service], [job], [compose], [env]) accepts the shared entry keys, then its own, except that [compose] refuses `env`, `env_file` and `env_from`: compose calls run without an entry's environment, so those values belong where compose itself reads them.

### [stack] (exactly one)

<!-- schema:stack -->
| key | type | default | required or repeat | meaning |
|---|---|---|---|---|
| `name` | id | none, required | required | project id; names the default state folder and the compose project; give each stack on a machine its own name |
| `title` | text | the name in capitals |  | first banner line |
| `subtitle` | text | empty |  | second banner line |
| `root` | path | the config file's folder |  | STACK_ROOT, the base for relative paths |
| `stages` | id list | prepare infra data build migrate services web verify |  | stages in run order, each named once; each heading reads N/M name |
| `parallel_stages` | id list | empty |  | stages that launch every service first, then wait for each; a service whose dependency is a service of the same stage is launched once that one is ready |
| `menus` | group list | one menu of every pickable entry |  | one interactive picker per group; an entry in no listed group is offered in none |
| `default_select` | selection | essential |  | the selection when nobody is at a terminal or every menu is answered blank; a blank answer to one of several menus takes that menu's entries from it |
| `require` | command | empty | repeat | a command every run needs, checked with command -v |
| `state_dir` | path | ${XDG_STATE_HOME:-$HOME/.local/state}/stack-up/NAME |  | history, lock, launch table, backups and repair log; when set, never the root, HOME or a folder above either; a relative XDG_STATE_HOME or HOME is ignored; the path cannot contain a vertical bar |
| `log_dir` | path | STATE_DIR/logs |  | run logs and entry logs; give it a folder of its own, because each entry log in it is truncated on every start; never the root, HOME or a folder above either |
| `keep_runs` | count | 0 |  | --clean keeps its own run log and the newest N before it; 0 keeps them all |
| `compose_files` | path list | empty |  | a space-separated list, so a space written in a path splits it (a space in the root or in a placeholder's value does not); no *, ? or [; each file is passed with -f on every compose call, which runs in STACK_ROOT; exported as STACK_COMPOSE |
| `compose_command` | command | docker compose |  | the compose front end, split on spaces into words (quotes are not parsed); its first word is the container engine |
| `engine_check` | command | docker info |  | engine-up probe, run before a selected compose entry starts, before a compose entry whose option is off is stopped, and by `--stop` whenever the config has a compose entry |
| `engine_start` | command | empty |  | how to start the engine; empty means stop with a hint |
| `engine_timeout` | seconds | 240 |  | deadline for the engine to come up |
| `open_url` | url | smoke_url |  | the address printed on the Open line when the smoke check passed or no smoke_url is set; marked "not checked" unless it is the smoke_url and the smoke check passed |
| `smoke_url` | url | empty |  | end-to-end check; one fetch per attempt |
| `smoke_expect` | status | 200 |  | HTTP status the smoke check needs |
| `smoke_forbid` | regex | empty |  | a pattern that must not appear in a non-empty smoke body |
| `smoke_requires` | entry | empty |  | run the smoke check only when this entry started |
| `smoke_timeout` | seconds | 200 |  | deadline for the smoke check |
| `classify_ignore` | regex | empty | repeat | log lines removed before signatures are tried |
| `defect_owner` | owner id | upstream |  | owner named on the known-defect summary |
| `keep_awake` | auto, off | auto |  | keep the machine awake with caffeinate while the run lasts |
| `repair` | auto, ask, never | auto |  | contract repair policy; --no-repair forces never |

### Shared entry keys: [service], [job], [compose], [env]

<!-- schema:entry -->
| key | type | default | required or repeat | meaning |
|---|---|---|---|---|
| `description` | text | empty |  | menu and plan text |
| `stage` | stage id | service: services, job: build, compose: infra, env: prepare |  | the stage it runs in |
| `tier` | essential, recommended, optional | optional |  | cumulative selection tiers |
| `groups` | group list | empty |  | menu membership and --select group:NAME |
| `pick` | yes, no | yes for service, no otherwise |  | appears in a menu |
| `always` | yes, no | no |  | runs even when nothing selected depends on it |
| `depends_on` | entry list | empty |  | runs after these; selecting it selects them |
| `option` | option id | empty |  | runs only when that option is on |
| `requires` | command | empty | repeat | a command that must exist when this entry is selected |
| `files` | path | empty | repeat | must exist before anything starts |
| `needs` | path | empty | repeat | must exist just before this entry starts |
| `needs_hint` | text | empty |  | printed when a needs path is missing |
| `precheck` | command | empty |  | must exit 0 before this entry starts |
| `precheck_hint` | text | empty |  | printed when the precheck fails |
| `on_fail` | abort, count, warn | count for service, abort otherwise |  | hard stop, counted failure (partial), or degraded |
| `env` | KEY=VALUE | empty | repeat | literal environment for this entry only; not used by [compose] |
| `env_file` | path | empty |  | one KEY=VALUE per line (an `export ` prefix is allowed), read literally and never sourced: quotes stay part of the value, `$VAR` is not expanded, and a value cannot span lines. Empty lines and lines whose first character is `#` are skipped; any other line, including one of only spaces or an indented `#`, that is not KEY=VALUE with a shell variable name as KEY is skipped, and its line number (never its text) is named on the entry's stderr. A file that is missing, a folder, or cannot be read when the entry is about to start fails that entry, named, before its command runs (for a service, before a copy an earlier run started is stopped); a readable file that is not a regular file, such as `/dev/null`, is read. Not used by [compose] |
| `env_from` | env list | empty |  | providers whose values only this entry receives; not used by [compose] |
| `log` | path | LOG_DIR/NAME.log |  | this entry's log, truncated on each start |
| `known_defect` | text | empty |  | never started: a DEFECT line, not counted as a failure |
| `known_defect_check` | command | empty |  | exit 0 means defective, so the entry is skipped |

### [service NAME]

<!-- schema:service -->
| key | type | default | required or repeat | meaning |
|---|---|---|---|---|
| `dir` | path | STACK_ROOT |  | working folder |
| `build` | command | empty |  | runs before start; if it fails, the entry fails as its on_fail says and is not started |
| `build_timeout` | seconds | 900 |  | build deadline |
| `start` | command | none, required | required | the long-running process, started in its own process group |
| `port` | port | empty |  | the port it listens on, exported as PORT |
| `port_env` | env name | empty |  | one more variable that carries the port; needs port |
| `url` | url | empty |  | shown in the menu and the summary |
| `ready` | probe | port when port is set, else alive 5 |  | port, http URL [STATUS], cmd COMMAND, or alive SECONDS |
| `ready_timeout` | seconds | 60 |  | readiness deadline |
| `stop_timeout` | seconds | 10 |  | grace between TERM and KILL |
| `toolchain` | none, nvm | none |  | nvm: put the node that nvm which names on PATH |

### [job NAME]

<!-- schema:job -->
| key | type | default | required or repeat | meaning |
|---|---|---|---|---|
| `dir` | path | STACK_ROOT |  | working folder |
| `run` | command | none, required | required | the job's command, run under a deadline in its own process group |
| `run_if` | command | empty |  | exit 0 runs the job, 1 skips it, anything else is an error |
| `timeout` | seconds | 600 |  | job deadline; a job still running past it is stopped with its process group |
| `trust_exit` | yes, no | yes |  | a non-zero exit fails the job |
| `ok_marker` | regex | empty |  | the job's output must contain it to pass |
| `fail_marker` | regex | empty |  | the job fails when its output contains it |
| `fail_detail` | regex | empty |  | up to five distinct matching lines of the job's output, each cut to 160 characters, are shown when the job fails |
| `reason_marker` | regex | empty |  | the first matching line of the job's output is quoted in the failure |
| `report` | command | empty |  | after the job passes, the first line it prints becomes one INFO line |

### [compose NAME]

<!-- schema:compose -->
| key | type | default | required or repeat | meaning |
|---|---|---|---|---|
| `services` | name list | none, required | required | compose service names |
| `ready` | healthy, running | healthy |  | healthy uses the health check when one exists, else the running state |
| `ready_timeout` | seconds | 180 |  | readiness deadline |

### [env NAME]

<!-- schema:env -->
| key | type | default | required or repeat | meaning |
|---|---|---|---|---|
| `run` | command | none, required | required | prints KEY=VALUE lines; values stay in memory |
| `timeout` | seconds | 60 |  | provider deadline |

### [check NAME]

<!-- schema:check -->
| key | type | default | required or repeat | meaning |
|---|---|---|---|---|
| `stage` | stage id | the stage before build, else the first stage |  | checks run at the end of this stage |
| `level` | required, advisory | required |  | an unmet required check blocks its dependent |
| `dependent` | entry or all | all |  | the entry that needs this check; a required check must run in an earlier stage than a named dependent |
| `probe` | command | none, required | required | exit 0 means satisfied |
| `gate` | check id | empty |  | a check that must pass first, in the same or an earlier stage, and that runs whenever this one does; if it does not pass, this one is not checked |
| `consequence` | text | empty |  | what goes wrong when it stays unmet |
| `repair` | command | empty |  | fixes the unmet condition of a required check; needs target or backup |
| `target` | path | empty |  | a file copied into the backups folder before the repair |
| `backup` | command | empty |  | a command that must succeed before the repair |

### [option NAME]

<!-- schema:option -->
| key | type | default | required or repeat | meaning |
|---|---|---|---|---|
| `question` | text | none, required | required | asked once per run at a terminal |
| `default` | yes, no | no |  | used without a terminal and on a blank answer |
| `when_off` | leave, stop | leave |  | stop: stop this option's entries while it is off |

### [signature NAME]

<!-- schema:signature -->
| key | type | default | required or repeat | meaning |
|---|---|---|---|---|
| `match` | regex | none, required | required | pattern tried against the output of an entry whose command failed |
| `also` | regex | empty |  | a second pattern that must also match |
| `owner` | owner id | none, required | required | who should act |
| `explain` | text | none, required | required | plain explanation shown with the owner |
| `applies_to` | kind list | every kind |  | service, job, compose, env |

### [heal NAME]

<!-- schema:heal -->
| key | type | default | required or repeat | meaning |
|---|---|---|---|---|
| `for` | entry list | none, required | required | services this heal may help |
| `when_log` | regex | empty |  | heal when the failed service's output matches |
| `when` | command | empty |  | heal when this probe exits 0 |
| `run` | command | none, required | required | the heal; one attempt per service per run; when it exits 0, the service is started once more |
| `settle` | seconds | 0 |  | wait after the heal, before the service is started again |
| `timeout` | seconds | 60 |  | heal deadline |
| `env_from` | env list | empty |  | providers whose values the heal's run receives (its when probe does not) |

### [owner NAME]

<!-- schema:owner -->
| key | type | default | required or repeat | meaning |
|---|---|---|---|---|
| `label` | text | none, required | required | how the owner is printed, for example THIS MACHINE |
| `advice` | text | empty |  | one more line printed under each fault for this owner |

## Readiness (`ready` in a service)

| form | ready when | notes |
|---|---|---|
| `port` | a process in the launched process group listens on `port` | the default when `port` is set; a listener outside the group does not count, and the failure names its PID |
| `http URL [STATUS]` | the URL answers STATUS (default 200), and, when `port` is set, the listener is in the launched group | one fetch per poll, 2 s each |
| `cmd COMMAND` | COMMAND exits 0 | run in the entry's environment, 10 s per attempt |
| `alive SECONDS` | the launched process is still running after SECONDS | the default without a port, for workers; SECONDS must be shorter than `ready_timeout` |

Every form also fails at once when the launched process exits, instead of waiting for `ready_timeout`.

## Selection (`default_select`, `--select`, the menu)

Words, separated by spaces or commas, in any case: `essential`, `recommended` (essential plus recommended), `all`, `none`, a number or a range such as `1-3` (either direction), an entry name, or `group:NAME`. A number is a position in the menu being answered, and otherwise among all pickable entries in file order. `all` wins wherever it appears, then `none`; everything else adds up, first mention first. Numbers are read in base 10, so `010` is ten. Only entries with `pick = yes` (services, by default) are listed; everything they `depends_on` is added with a note.

## Owners (`[owner ID]`)

An entry whose command ran and failed has its output matched against the `[signature]` sections in file order, and the first match names an owner; a failure found before its command runs, such as a missing `needs` path or a failed precheck, names a fixed owner. The five built-in owner ids are `this-machine`, `local-config`, `local-data`, `upstream` and `needs-a-look`; an `[owner]` section can relabel one of them or add a new id. With no match, the owner is `needs-a-look`; with no output, `this-machine`.

## Exit status

| status | meaning |
|---|---|
| 0 | open: nothing counted failed or degraded; `--stop` left nothing running; or another mode finished (`--plan` with no port clash, `--check` with every required check met, `--clean`, `--print-*`) |
| 1 | partial (a counted failure), stopped early (an abort), `--plan` found two selected services on one port, `--stop` left something running or could not check it, `--check` found a required check unmet or not checked, or `--clean` was declined or left a file it could not delete |
| 2 | usage error, invalid config, or an environment it cannot run in (no absolute `XDG_STATE_HOME` or `HOME`, a state path with a vertical bar, no here-document file); nothing ran |
| 3 | degraded: an `on_fail = warn` entry failed, or the smoke check failed |
| 4 | busy: another run of the same stack holds its lock |
| 129, 130, 143 | interrupted by HUP, INT or TERM |
