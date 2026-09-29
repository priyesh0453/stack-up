# Changelog

All notable changes to this project are recorded here. The format is based on Keep a Changelog, and versions follow Semantic Versioning.

## [Unreleased]

- Planned: a Homebrew tap, so `brew install` becomes the third way to get it.

## [0.1.0]

First public version, not yet tagged; I add the date when I cut the tag. A reference design, rewritten from scratch. The README lists what it does and what it never does; docs/LIMITATIONS.md lists its known limitations; docs/ARCHITECTURE.md gives the rules every change must keep and names the tests that pin each one where a test does, and docs/CONFIG.md every config key. This entry does not restate them.

### Added

- `bin/stack-up`, the engine: one config file, `stack.conf`, validated in full before anything runs; ordered stages; readiness probes with a deadline, where a `port` probe counts only a listener in the launched process group; `--stop` driven by the launch table, with compose services stopped per project and never removed; failure owners from ordered signatures; contract checks that back a file up before repairing it.
- The modes `--plan`, `--check`, `--stop`, `--clean`, `--print-config`, `--print-schema`, `--print-paths` and `--version`.
- `install.sh` and `uninstall.sh`, which add and remove the `stack-up` link (and, with `--copy`, a copy of the engine) under a prefix, `~/.local` by default.
- A demo stack in `examples/demo`, built from bash, nc and other stock tools.
- `tests/`, with unit and end-to-end suites run on the stock bash 3.2.
- `AGENTS.md` and `skills/stack-up/SKILL.md` for coding agents, and `docs/ADAPT.md` for porting the design to another platform.
