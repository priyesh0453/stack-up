# Instructions for coding agents

This repository is stack-up, a bash tool that starts a local development stack from one config file (`stack.conf`) and on `--stop` signals only the processes it launched and asks compose to stop the services its config names. People copy it and adapt it, and I wrote these instructions for any coding agent working in a copy.

The task-level guide is the skill at `skills/stack-up/SKILL.md`. Read it before changing a config or the engine.

## Safe to run at any time

These read files and print; they start nothing and write nothing:

```sh
bin/stack-up --help
bin/stack-up --version
bin/stack-up --print-schema
bin/stack-up --config PATH --print-config
bin/stack-up --config PATH --print-paths
bin/stack-up --config PATH --plan
bash -n bin/stack-up
shellcheck -x bin/stack-up install.sh uninstall.sh
```

`shellcheck` is not part of a stock Mac; skip that line when it is not installed, and never install it for the person.

`--check` also writes nothing, but it runs the `probe` commands from the config, so read them first.

## Run only when the person asks

- `bin/stack-up --config PATH` (with or without `--yes`): starts processes and runs the config's commands for the entries it selects, with their checks and heals; for an option that is off with `when_off = stop`, it also stops that option's entries, including a compose stop of its `[compose]` services.
- `bin/stack-up --config PATH --stop`: stops the process groups that stack recorded, and asks compose to stop its `[compose]` services under the project name (containers started by hand under that name too).
- `bin/stack-up --config PATH --clean`: deletes that stack's rotated launch tables, launch tokens no record uses, and (with `keep_runs` above 0) its older run logs.
- `./install.sh` and `./uninstall.sh`: change the person's `~/.local/bin` (and, with `--copy`, `~/.local/share/stack-up`).
- `tests/run-all.sh`: starts short-lived demo services on free 127.0.0.1 ports and stops them again; it takes a few minutes.

When the stack was started with `--root`, give `--stop`, `--clean` and `--print-paths` the same `--root`. Without it, a `state_dir`, `log_dir` or `compose_files` that is relative or built on `${STACK_ROOT}` resolves against another folder, so those modes look at the wrong paths; with such a `state_dir`, `--stop` reports nothing to stop while the stack still runs.

## Never

- Never edit anything under `lib/`. It is vendored and pinned by `lib/MANIFEST.sha256`; the tests fail on any change.
- Never add code or config that stops programs by name or pattern (`pkill`, `killall`), signals a parent process, or signals any process group the tool did not create. Signals belong only in the three helpers `su_alive` (signal 0 to one PID), `su_signal_group` (a group this tool created: a recorded one, a launch whose record could not be written, or a `--check` probe; or signal 0 to ask whether a group exists) and `su_signal_launch` (a process launched a moment earlier that did not get its own group).
- Never add commands that remove containers, volumes or images, or that prune anything. I left out a destroy path on purpose.
- Never run `sudo`, install software, or change system settings on the person's behalf.
- Never put a secret in `stack.conf`, on a command line, or in a log. Secrets come from an `[env]` provider and reach only the entries and heals that name it in `env_from`.
- Never weaken a test to make it pass, and never claim a test passed without running it.

## When you change things

- A new config key: add a row to `su_schema_rows` in `bin/stack-up`, then the matching row in `docs/CONFIG.md`.
- A new flag: add it to `su_flag_table`, `su_parse_args` and the flag table in `README.md`.
- Keep the text files ASCII-only and the scripts bash 3.2 compatible (no associative arrays, no `mapfile`, no `${var,,}`).
- Finish with `tests/run-all.sh` (all files must print `RESULT: PASS`; it runs real processes against real deadlines, so run it on a machine that is not already saturated) and `shellcheck -x`.
