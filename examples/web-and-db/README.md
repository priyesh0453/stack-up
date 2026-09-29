# A web app with a database

This is the stack shape I meet most often: a database in a container, a migration that runs when the schema changed, an API and a web front end started from this machine's node, and one local file for the secrets. Every key in `stack.conf` has a comment saying why it is there and what else you could write; `compose.yaml`, `.env.example` and the two scripts are commented the same way.

What it shows:

- `[env secrets]` reads `.env` through `read-secrets.sh`, so the values reach only the migration, the seed job and the api, in their own processes, and never a command line or a log.
- `[compose db]` starts the database from `compose.yaml` and waits for its health check, not only for its process.
- `[job migrate]` runs when a migration file was added since the last run; `[job seed]` runs behind the `seed` option.
- `[check web-api-url]` repairs `web/.env.local` after copying it to the backups folder, and only when `web` is selected.
- `[service api]` proves readiness on its health page and `[service web]` on its port; two `[heal]`s reinstall node modules once when the log says they are missing.
- Four `[signature]`s name an owner for the failures I meet most, and one `[owner]` adds an advice line under the faults that name it.

`tests/unit-examples.sh` validates the config with `--print-config` and `--plan`, with and without a container engine on PATH, and checks both scripts. I have not run this example end to end: the `api/` and `web/` folders it names are yours.

To adapt it:

1. Copy this folder next to your project and put your api and web beside `stack.conf`, or point each `dir` at them.
2. Copy `.env.example` to `.env` and fill in the values; the `.gitignore` here keeps `.env` out of git.
3. Change the image and the health check in `compose.yaml` to your database, the two `start` lines to how you start your services, and the ports where they differ.
4. From the repository folder, before you copy it (after the copy, give `--config` the path of your copy), read the plan until it says what you expect, then start the stack and stop it:

```sh
bin/stack-up --config examples/web-and-db/stack.conf --plan
bin/stack-up --config examples/web-and-db/stack.conf --yes
bin/stack-up --config examples/web-and-db/stack.conf --stop
```
