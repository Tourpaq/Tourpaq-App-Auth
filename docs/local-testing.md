# Testing the whole stack locally

This runs the auth app and every app that signs in through it on your Mac: the IRM, KPI, Logs Analyzer, Azure
Cost and the Dashboard. You sign in through the auth app's fake identity provider, the same way people will
sign in through Entra in production. You can then check sign-in, roles, "no access", removed grants, personal
tokens, the index, the Dashboard's roles and the temporary Entra hop.

`bin/dev-stack` sets it all up. It **never touches your `.env` files or your development databases**:

- Every container gets its settings from a generated `.env.auth-local` instead of `.env`.
- Every database is a separate stack database.

Everything is SQLite except KPI, which uses its own TimescaleDB dev container. No Postgres container is started:
checking Postgres is CI's job.

## Prerequisites

- Docker Desktop running.
- The repositories side by side in one folder (`~/code/Tourpaq-App-Auth`, `Tourpaq-App-IRM`, `Tourpaq-App-KPI`,
  `Tourpaq-App-Logs-Analyzer`, `Tourpaq-App-Azure-Cost`, `Tourpaq-App-Dashboard`). If they are somewhere else, set
  `CODE_DIR=/path`.
- Each app's `bin/docker-dev` must understand `ENV_FILE=.env.auth-local` and `DOCKER_NAME` (all five do now). It
  falls back to `.env` when `ENV_FILE` is not set, as before. It publishes its port only for the server (no
  arguments, `bin/rails server`, or `bin/dev` where the app has one), judged by the command words, so one-off
  commands run beside the stack.
- These ports must be free: **3050** (auth), **3030** (IRM), **3040** (KPI), **3020** (Logs), **3010** (Azure Cost)
  and **4013** (Dashboard). Stop your own dev servers first, for example `docker stop kpi-web`. You can also move an
  app to another port, for example `KPI_PORT=3041 bin/dev-stack up`. The script then registers that port's
  redirect URI on the app's client in the stack database (audited as `client.updated`).
- Chrome, Edge or Safari. They all resolve `*.localhost` to your machine. From the command line, `curl` does too.

## What `bin/dev-stack` does

```sh
cd ~/code/Tourpaq-App-Auth
bin/dev-stack            # prepare only, then print the start commands
bin/dev-stack up         # prepare, then start everything in the background and wait until it answers
```

Preparing (both commands do this):

1. **The auth app** gets its own `.env.auth-local`:
   - the three hosts: `APP_URL=http://auth.localhost:3050` (the issuer), `INDEX_URL=http://index.localhost:3050` and
     `ADMIN_URL=http://admin.localhost:3050`;
   - `AUTH_INTERNAL_HOSTS=host.docker.internal:3050`;
   - `DATABASE_URL=sqlite3:storage/stack.sqlite3`.

   The script then runs `db:prepare` (create, migrate, seed). The seeds bring the DK Tech admins, the apps, their
   clients and the index content.
2. **Client secrets** are created with `bin/rails "auth:client_secret[<client>]"` for `irm-web`, `kpi-web`,
   `logs-web`, `azure-cost-web` and `dashboard-web`. Each one is audited as `client.secret_created`.
   - When you run the script again, it keeps a secret that is still valid. It compares the SHA-256, so the secret
     itself is never sent anywhere.
   - When a client already holds two secrets, the script deletes the oldest one (audited as
     `client.secret_deleted`).
   - The script refuses to do any of this on a database other than `storage/stack.sqlite3`.
3. **Every app** gets a `.env.auth-local`. It is git-ignored (`/.env*`) and only you can read it (mode 600). It
   holds:
   - `LOGIN_ISSUER=http://auth.localhost:3050`;
   - `LOGIN_INTERNAL_URL=http://host.docker.internal:3050`. The app's container calls the back channel there:
     `auth.localhost` inside a container is the container itself;
   - `LOGIN_CLIENT_ID` and `LOGIN_CLIENT_SECRET`;
   - `LOGIN_ACCESS_CACHE_SECONDS=30`, so a removed grant takes effect within a minute. Change it with
     `STACK_ACCESS_CACHE_SECONDS`;
   - its stack database:
     - IRM, Azure Cost and the Dashboard: `storage/stack.sqlite3`;
     - Logs Analyzer: `storage/stack.sqlite3`, plus `storage/stack_queue.sqlite3` and `storage/stack_data/`;
     - KPI: `DB_SUFFIX=_stack`, which means the databases `tourpaq_kpi_development_stack` and
       `tourpaq_kpi_ts_development_stack` in its TimescaleDB container;
   - what the app needs locally:
     - IRM and KPI: `APP_URL`;
     - Logs Analyzer: `PORT` (its API checks tokens as in production, because sign-in is on);
     - Dashboard: `AUTH_ENTRA_CALLBACK_URL=http://auth.localhost:3050/auth/entra_id/callback`, plus
       `AUTH_ADMIN_URL` and `AUTH_INDEX_URL`.

   Then the script runs `db:prepare` in each app.

Starting (`up` only):

1. The auth app starts as the container `stack-auth`.
2. The **first time only**, the script loads the Dashboard's sample access data and imports it. It:
   - writes the Dashboard's four pre-cutover groups (Administrators `*`, Support, Support Manager, Management) and
     five people into the Dashboard's stack database;
   - exports them with the Dashboard's own `bin/rails auth:export`;
   - imports the file here with `auth:import_dashboard` (a dry run, then `APPLY=1`);
   - runs the Dashboard's `auth:verify_import` against the running auth app.

   You can run this again with `bin/dev-stack dashboard-import`. A second apply is refused because the import was
   already applied, which is the import's rule.
3. The script pushes the Dashboard's permission catalogue (`bin/rails auth:push_catalogue`).
4. The apps start as `stack-irm`, `stack-kpi`, `stack-logs`, `stack-azure-cost` and `stack-dashboard`. Their logs
   go to `tmp/dev-stack/<name>.log`. The script waits until each one answers `/up`.

Once the apps' Docker images and gems are built (the first `bin/docker-dev` in each repository builds them), `up`
takes one to two minutes, even from scratch.

### Starting by hand instead

`bin/dev-stack` (without `up`) prints these commands. Run each in its own terminal:

```sh
cd ~/code/Tourpaq-App-Auth           && ENV_FILE=.env.auth-local bin/docker-dev
cd ~/code/Tourpaq-App-IRM            && ENV_FILE=.env.auth-local WEB_PORT=3030 bin/docker-dev bin/rails server -b 0.0.0.0 -p 3030 -P tmp/pids/stack-server.pid
cd ~/code/Tourpaq-App-KPI            && ENV_FILE=.env.auth-local WEB_PORT=3040 bin/docker-dev bin/rails server -b 0.0.0.0 -p 3040 -P tmp/pids/stack-server.pid
cd ~/code/Tourpaq-App-Logs-Analyzer  && ENV_FILE=.env.auth-local WEB_PORT=3020 bin/docker-dev bin/rails server -b 0.0.0.0 -p 3020 -P tmp/pids/stack-server.pid
cd ~/code/Tourpaq-App-Azure-Cost     && ENV_FILE=.env.auth-local WEB_PORT=3010 bin/docker-dev bin/rails server -b 0.0.0.0 -p 3010 -P tmp/pids/stack-server.pid
cd ~/code/Tourpaq-App-Dashboard      && ENV_FILE=.env.auth-local WEB_PORT=4013 bin/docker-dev bin/rails server -b 0.0.0.0 -p 4013 -P tmp/pids/stack-server.pid
```

The `-P tmp/pids/stack-server.pid` lets a stack server run next to your own dev server's pid file. The Dashboard's
sample import and catalogue push happen only with `up`. By hand, run `bin/dev-stack dashboard-import` once the auth
app is running, then:

```sh
cd ~/code/Tourpaq-App-Dashboard && ENV_FILE=.env.auth-local bin/docker-dev bin/rails auth:push_catalogue
```

## URLs

| What | URL |
| --- | --- |
| Auth (the issuer) | http://auth.localhost:3050 |
| Fake identity provider | http://auth.localhost:3050/dev/sign_in |
| Index, profile, tokens | http://index.localhost:3050, http://index.localhost:3050/tokens |
| Admin | http://admin.localhost:3050 |
| IRM | http://localhost:3030 |
| KPI | http://localhost:3040 |
| Logs Analyzer | http://localhost:3020 |
| Azure Cost | http://localhost:3010 |
| Dashboard | http://localhost:4013 |

`bin/dev-stack status` shows what is running, and `bin/dev-stack logs kpi` follows a log.

## Who to sign in as

On the fake identity provider's page, pick a user or type any address. The oid is derived from the address, so
the same address is always the same "Entra account".

| Address | What they have |
| --- | --- |
| `mwi@tourpaq.com` | Admin of the auth app. Admin in IRM, KPI, Logs, Azure Cost and Index through DK Tech. Dashboard role **Administrators** (`*`) from the sample import |
| `jjr@tourpaq.com`, `mso@tourpaq.com`, `sar@tourpaq.com` | The same as mwi, but **no Dashboard role**: use them for "no access" on the Dashboard |
| `support.agent@tourpaq.com` | Only the Dashboard role **Support** (dashboard, tasks, customers). No access to the other apps |
| `manager@tourpaq.com` | Dashboard roles **Management** and **Support Manager** |
| `youtrack.only@tourpaq.com` | Pre-created (no oid in the Dashboard export), Dashboard role Support; bound by email at the first sign-in |
| `former@tourpaq.com` | Inactive in the Dashboard export, so no Dashboard role |
| any other address | A new **pending** user: "waiting for access" until an admin gives them something |

Use one browser profile (or a private window) per person: the auth session is a cookie on auth.localhost. To
switch person, sign out at http://auth.localhost:3050 or use another window.

## What to try

Tick these off. The automated run on 17 Oct 2026 passed all of them (the report lists the details).

**Every app** (IRM, KPI, Logs Analyzer, Azure Cost, Dashboard)

- [ ] Open the app signed out. It sends you to auth.localhost, where you pick `mwi@tourpaq.com` and land back in
      the app, signed in, with the role **admin** in the sidebar or header (Dashboard: the admin pages open).
- [ ] Open the next app. You are signed in silently (the auth session is still alive).
- [ ] As `support.agent@tourpaq.com`, open IRM, KPI, Logs or Azure Cost. You get the auth app's "You don't have
      access to …" page, not the app.
- [ ] As a new address, for example `new.person@tourpaq.com`, you get the same page. At http://auth.localhost:3050
      you see "waiting for access".

**Grants and the re-check** (admin.localhost)

- [ ] Sign in at auth.localhost as a new address (pending). Then, as mwi, open http://admin.localhost:3050 →
      Users → that person, and grant **viewer** in IRM, KPI, Logs and Azure Cost and **Support** in the Dashboard.
- [ ] As that person, each app now opens with the role viewer (Dashboard: /customers opens, /admin is refused).
- [ ] Change their KPI role to editor in admin. Within about 30 seconds, KPI shows editor.
- [ ] Remove their grants. Within about 30 seconds, the next page in each app ends the session:
  - IRM: "Your user is disabled";
  - KPI and Logs: "Signed out";
  - Azure Cost: back to auth's "no access";
  - Dashboard: the sign-in page.
- [ ] Optional: "Sign out everywhere" on a user's admin page ends their sessions in the apps at the next re-check (also a session that started in the same second).

**Personal tokens** (http://index.localhost:3050/tokens)

- [ ] Create a token for each app (the Dashboard offers `public`/`all`, the others `read`/`read_write`). It is
      shown once.
- [ ] Call the app with it. Put the token in a shell variable first, so it does not end up in your shell history:
      `read -s T` and paste it.

      ```sh
      curl -H "Authorization: Bearer $T" http://localhost:3030/api/v1/me          # IRM
      curl -H "Authorization: Bearer $T" http://localhost:3040/api/v1/kpis        # KPI
      curl -H "Authorization: Bearer $T" http://localhost:3020/api/v1/findings    # Logs Analyzer
      curl -H "Authorization: Bearer $T" http://localhost:3010/api/v1/inventory   # Azure Cost
      curl -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
           -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' http://localhost:4013/mcp   # Dashboard MCP (also /mcp on IRM, KPI, Logs)
      ```

- [ ] Call another app with the same token. You get **401**.
- [ ] Revoke the token on the Tokens page. Within a minute (the introspection cache), the app refuses it.

**The index** (http://index.localhost:3050)

- [ ] As mwi you see "Your apps", every section (also the DK Tech / RO DevOps tables) and an **Admin** link.
- [ ] As support.agent you see only what applies to them: the Dashboard entry with the role Support, and no IRM,
      KPI or Logs entries and no technical sections. http://index.localhost:3050/apps/irm is a 404 for them.

**The Dashboard**

- [ ] mwi (Administrators, `*`) opens the administration. support.agent (Support) opens customers but not admin.
      manager has the management overview.
- [ ] In admin.localhost → Apps → Dashboard, edit a role. The catalogue the Dashboard pushed shows as
      checkboxes. Remove `module:customers:view` from Support, and within 30 seconds support.agent can no longer
      open customers.
- [ ] The Entra hop: `curl -i 'http://localhost:4013/auth/entra_id/callback?code=x&state=y'` answers `302` to
      `http://auth.localhost:3050/auth/entra_id/callback?code=x&state=y`, with the query unchanged. (The auth app
      then refuses the made-up state, which is expected.)
- [ ] The cutover rehearsal: `bin/dev-stack dashboard-import` shows the export, the dry run, the refused second
      apply and the Dashboard's `auth:verify_import` ("No differences").

## The browser extensions (unpacked)

Both extensions have a fixed id (manifest `key`), and the stack's seeds register their redirect URIs.

- **Tourpaq Index** (`clients/index-extension` in this repository):
  1. Open `chrome://extensions` → Developer mode → **Load unpacked** → pick the folder.
  2. In the panel, **Settings** → `http://index.localhost:3050` → save → **Sign in with Tourpaq**. The sign-in
     window shows the fake identity provider. Pick mwi (DK Tech has access to the app Index).
  3. The panel shows the same index as the web page.
- **IRM** (`../Tourpaq-App-IRM/clients/chrome-extension`):
  1. Load it unpacked the same way.
  2. In the options, set the server to `http://localhost:3030`.
  3. **Sign in with Tourpaq** goes through auth.localhost. You need access to the IRM (mwi has it).

Both use `chrome.identity.launchWebAuthFlow`, which works in Chrome and Edge, not in Safari.

## Stopping and resetting

```sh
bin/dev-stack down     # stops stack-auth and the stack-* app containers (your own containers are left alone)
bin/dev-stack reset    # down, then deletes every stack database, KPI's _stack databases and the .env.auth-local files
```

`bin/dev-stack` or `bin/dev-stack up` recreates everything from scratch: new secrets, fresh seeds and a fresh
sample import. Your `.env` files and `storage/development.sqlite3` are never touched.

## When something does not work

- **"port … is in use"**: another server is on that port (`docker ps`, `lsof -nP -iTCP:3040 -sTCP:LISTEN`). Stop
  it, or move the app with `<APP>_PORT=…`.
- **An app shows "sign-in is switched off"**: it was started without `ENV_FILE=.env.auth-local`.
- **The app says the auth app cannot be reached**: is `stack-auth` running (`bin/dev-stack status`)? Is
  `AUTH_INTERNAL_HOSTS` set in the auth app's `.env.auth-local`? It is regenerated on every run.
- **`invalid_client`**: the secret in the app's `.env.auth-local` belongs to an older stack database. Run
  `bin/dev-stack` again and restart the app.
- **The Dashboard prints "WARNING: DATABASE_URL is set in development"**: this is expected. The stack points the
  Dashboard at `storage/stack.sqlite3`.
- Logs: `tmp/dev-stack/*.log` in this repository, or `bin/dev-stack logs <name>`.
