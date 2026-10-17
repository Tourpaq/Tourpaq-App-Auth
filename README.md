# Tourpaq Auth

The single sign-in and access service for all journeybooking apps. Its issuer is
**https://auth.app.journeybooking.eu**; the index is at **https://index.app.journeybooking.eu** and the
administration at **https://admin.app.journeybooking.eu**, all one Rails app. People sign in once with their
Microsoft Entra ID account; the auth app knows which apps each person may use and with which role, and every app (the
IRM, KPI, Logs Analyzer, Azure Cost, the Dashboard…) asks it before showing anybody any data.

**[SPECS.md](SPECS.md) is the specification and the source of truth** for scope and decisions (§24 for the hosts).

## Status

Built: the Rails skeleton, the full data model, Entra sign-in (with a fake identity provider for development and
tests), sessions, seeds and the break-glass tasks (milestone M1); the OIDC provider, authorization API, tokens and admin
UI (M2–M5); the auth app's side of M7: permission-carrying roles, per-app token scopes, the catalogue push and the
Dashboard import (SPECS.md §21, §23); and the host structure of §24: the auth, index and admin hosts, the back-channel
hosts, the temporary Entra redirect hop through home.app; and the index merged from Tourpaq-App-WWW (§24.3): its
content, admin, search, API and browser extension (see [The index](#the-index-indexapp)).

## The hosts

One Rails app, one deployment, three host names (SPECS.md §24.1), all behind NetBird:

| Host | Serves | Locally |
| --- | --- | --- |
| `auth.app.journeybooking.eu` (`APP_URL`, **the issuer**) | Entra sign-in, the OIDC provider, the authorization API, introspection, the catalogue push, "waiting for access", "no access", sign out. `/` sends a signed-in user to the index | http://auth.localhost:3050 |
| `index.app.journeybooking.eu` (`INDEX_URL`) | The index (WWW's front page, sections, entries, docs, search, the extension's API), profile, personal tokens. Signs in through auth.app as the internal OIDC client `index` | http://index.localhost:3050 |
| `admin.app.journeybooking.eu` (`ADMIN_URL`) | The admin UI only (users, groups, apps, and the index content under `/index`), limited to admins in NetBird. Signs in through auth.app as the internal client `admin` | http://admin.localhost:3050 |

Each host's routes are 404 on the others, and each host has its own host-only cookies, so a session on one is no
session on another. The admin host checks on every request that the user is still an active admin, and optionally that
the client address is in `ADMIN_ALLOWED_CIDRS`. The index host checks that the user is still active, and sends a user
without any access to auth.app's "waiting for access".

**Back-channel hosts** (`AUTH_INTERNAL_HOSTS`, e.g. `host.docker.internal:3050,auth:3050`): apps on a shared Docker
network (or in local testing) may call discovery, JWKS, `/oauth/token`, `/oauth/introspect`, `/oauth/revoke`,
`/oauth/userinfo` and `/api/v1/*` there; every other path on such a host is 404. The issuer, the `iss` claim,
discovery's URLs and every redirect always come from `APP_URL`. The apps' side is the gem's `LOGIN_INTERNAL_URL`.

**The Dashboard stays at home.app.journeybooking.eu**, an ordinary client of auth.app. The Entra registration's only
redirect URI is home.app's `/auth/entra_id/callback`, so until IT adds auth.app's own, the auth app sends
`ENTRA_REDIRECT_URI=https://home.app.journeybooking.eu/auth/entra_id/callback` and the Dashboard forwards that GET to
auth.app (SPECS.md §24.2). While the hop is in use, nobody can sign in when the Dashboard is down.

## Local development

Rails 8.1 / Ruby 4.0.7. The host Ruby is not used: everything runs in the dev image through `bin/docker-dev`
(gems in the `auth_bundle` volume). **SQLite only** under `./storage` (SPECS.md §24.4): no local Postgres; Postgres
is checked in CI and runs in production.

```sh
cp .env.example .env
bin/docker-dev bin/rails db:prepare          # create, migrate, seed (admins, groups, apps, clients, the index's seed content)
bin/docker-dev                               # http://auth.localhost:3050, http://index.localhost:3050, http://admin.localhost:3050
```

Browsers resolve `*.localhost` to your machine. Real Entra credentials are not used locally. Sign in with the **fake
identity provider** at http://auth.localhost:3050/dev/sign_in: pick a seeded user or type any email. It produces the
same claims Entra would, so a pre-created user is bound and a new address becomes a pending user, exactly as in
production. Then open http://index.localhost:3050: it signs you in through auth.localhost (the real OIDC round trip).
The admin host does the same at http://admin.localhost:3050, and has a dev-only shortcut at
http://admin.localhost:3050/dev/admin_sign_in.

Solid Queue (cleanup jobs) runs inside Puma, in development as in production.

### Running an app against the local auth app

```sh
bin/docker-dev bin/rails "auth:client_secret[irm-web]"   # a new secret, printed once with the LOGIN_* lines (audited)
```

Put the printed `LOGIN_ISSUER=http://auth.localhost:3050`, `LOGIN_CLIENT_ID` and `LOGIN_CLIENT_SECRET` into the app's
environment. An app in another container reaches the auth app's back-channel through
`LOGIN_INTERNAL_URL=http://host.docker.internal:3050` when this app has `AUTH_INTERNAL_HOSTS=host.docker.internal:3050`
(the browser still goes to auth.localhost). The task is refused in production unless `FORCE=1`.

### The whole stack locally

`bin/dev-stack up` runs this app with the IRM, KPI, Logs Analyzer, Azure Cost and the Dashboard, all signing in
through it, each on its own stack database. It generates a `.env.auth-local` per repository, so nobody's `.env` or
development database is touched. `bin/dev-stack down` stops it, and `bin/dev-stack reset` removes the stack again.
**[docs/live-entra-test.md](docs/live-entra-test.md)** puts the auth app live on Coolify with real Entra ID, using the registration's existing home.app redirect URI and no change from IT. **[docs/local-testing.md](docs/local-testing.md)** walks through it: the URLs, who to sign in as, a checklist per app,
the browser extensions, and how to reset.

### Tests

```sh
bin/docker-dev bin/rails test
bin/docker-dev bin/ci                        # audits, brakeman, tests, seeds
TEST_DB=storage/test_other.sqlite3 PARALLEL_WORKERS=1 bin/docker-dev bin/rails test   # a second run side by side
clients/ruby/bin/docker-test                 # the gem's own tests
```

Tests use the hosts `auth.example.com`, `index.example.com`, `admin.example.com` and the back-channel host
`auth-internal.example.com:3050`, whatever `.env` says. They never talk to Entra: OmniAuth's test mode with the fake
identity provider's claims, a fake JWKS for the ID-token checks, and a fake token endpoint for the redirect-hop test.

### Console tasks (break-glass, SPECS.md §15)

```sh
bin/docker-dev bin/rails "auth:admin[someone@tourpaq.com]"     # make an admin (pre-creates an unknown email)
bin/docker-dev bin/rails "auth:disable[someone@tourpaq.com]"   # disable: sessions end, extension tokens revoked
```

### The Dashboard import (SPECS.md §23.5)

The Dashboard's `bin/rails auth:export > dashboard-export.json` writes its users, groups, memberships, resolved
permissions and live tokens. The import is a dry run unless `APPLY=1`, runs in one transaction, is idempotent and
audited (`import.dashboard`), and prints every create, change and skip, a check of each user's permissions against the
export, and the token owners to tell before the cutover:

```sh
bin/docker-dev bin/rails "auth:import_dashboard[dashboard-export.json]"             # dry run: the report only
APPLY=1 bin/docker-dev bin/rails "auth:import_dashboard[dashboard-export.json]"     # apply
docker exec -it -e APPLY=1 <web container> bin/rails "auth:import_dashboard[/tmp/dashboard-export.json]"   # deployed
```

Once applied, applying again is refused unless `FORCE=1 APPLY=1`; even then roles and grants changed in the admin
UI since the applied run are left as they are (listed as skips), so a second run cannot bring back removed access.
The cutover is rehearsed by importing a production export into a local SQLite auth app (SPECS.md §23.6), never by
restoring a database copy.

## The index (index.app)

Tourpaq-App-WWW (the index at www.app) is merged into this app (SPECS.md §24.3). The index host shows WWW's front page
for the signed-in user: their apps with their role ("Your apps", for apps without an entry of their own), the sections
laid out as cards, tiles into the technical (table) sections and the docs, and search in the sidebar (press `/`).

- **Who sees what** is decided in the query on every page, in search and in the API: an entry tied to one of our apps
  is shown only to the users with access to that app (with their role); every other entry, and every section, is
  shown to everyone signed in or only to the chosen groups (WWW's technical groups: DK Tech and RO DevOps).
- **Editing** is on the admin host under **Index content** (`/index`): entries with their links, sections with their
  layout and visibility, access levels and login methods (the two pills; a missing one shows as `Access?` / `Login?`
  and is listed on the overview), docs, doc sections, site settings. Every change is audited (`index.*`). Markdown is
  sanitised and URLs must be http(s) or a site path, as on WWW.
- **The browser extension** "Tourpaq Index" is in [`clients/index-extension`](clients/index-extension/README.md). It
  signs in through auth.app as `index-extension` and reads `GET /api/v1/index` on the index host with its
  `tpx_index_` token (WWW's response shape, fields only added). `node clients/index-extension/tools/auth_test.mjs`
  and `tools/smoke.mjs` are its tests; `bin/package-index-extension` zips it.
- **A fresh database** gets WWW's seed content (`db/seeds/index`), once, into an empty index.

### Moving WWW's production content (SPECS.md §24.3)

1. Export on the running WWW (the deployed version; the script is self-contained):

   ```sh
   docker cp script/index_export.rb <www container>:/rails/script/index_export.rb      # from ../Tourpaq-App-WWW
   docker exec <www container> bin/rails runner script/index_export.rb - > tourpaq-index-export.json
   ```

2. Import here, a dry run first (it reports every create, change and skip, and the rows only here), then apply. It is
   idempotent, never deletes, and keeps what admins changed here after an earlier applied import:

   ```sh
   bin/docker-dev bin/rails "auth:import_index[storage/tourpaq-index-export.json]"            # local rehearsal
   APPLY=1 bin/docker-dev bin/rails "auth:import_index[storage/tourpaq-index-export.json]"
   docker exec -e APPLY=1 <web container> bin/rails "auth:import_index[/tmp/tourpaq-index-export.json]"   # deployed
   ```

3. In Coolify, redirect `www.app.journeybooking.eu` to `https://index.app.journeybooking.eu` (paths are the same:
   `/groups/…`, `/apps/…`, `/docs/…`), and retire Tourpaq-App-WWW.

Rehearse it into a local SQLite auth app (never a local Postgres, §24.4).

## Deployment (Coolify on Hetzner)

1. The **Tourpaq App Platform** stack (`../Tourpaq-App-Platform`) must be deployed first: it owns the
   `tourpaq-platform` network and the production PostgreSQL.
2. Create the database there: `bin/create-app tourpaq_auth`. It prints the `DATABASE_URL` (host `postgres`). That
   is the only database: the job queue tables live in it too.
3. DNS for the three host names, and the NetBird rules (admin.app limited to the admins).
4. Deploy this repo in Coolify as a Docker Compose resource. Put **all three domains on the one `web` service**
   (port 3050): `auth.app.journeybooking.eu`, `index.app.journeybooking.eu` and `admin.app.journeybooking.eu`. Set the
   environment variables from `.env.example`: at least `SECRET_KEY_BASE`, `DATABASE_URL`, `APP_URL`, `INDEX_URL`,
   `ADMIN_URL`, the three `ENTRA_*` values from IT (only in Coolify, never in the repository), `ENTRA_REDIRECT_URI`
   while the hop through home.app is in use, and `OIDC_SIGNING_KEY`. `AUTH_INTERNAL_HOSTS` only if apps call the
   back-channel by container name.
5. The web container migrates and seeds on every start (the seeds never overwrite existing rows). The health
   check is `/up` (no database); `/up/ready` also checks the database.
6. Sign in as each admin. For a fresh install without the seeded admins:
   `docker exec -it <web container> bin/rails "auth:admin[email]"`.

The compose file publishes no host port: only the proxy (and containers on a shared network, through
`AUTH_INTERNAL_HOSTS`) reaches the app. Backups come from the platform's nightly Postgres dump.

## Repository layout

- The Rails app at the root. Routes per host in `config/routes/` (auth, oauth, api, index, admin, dev).
- `clients/ruby`: the shared Ruby client gem `tourpaq_auth` for the apps (SPECS.md §13); apps vendor it with
  `bin/sync-client <app dir>`.
- `clients/index-extension`: the index's browser extension (SPECS.md §24.3).
- `db/seeds/index`: the index's seed content (from WWW), loaded once into an empty index.
- `SPECS.md`: the specification; updated in the same commit as the behaviour it describes.
- `CLAUDE.md`: notes for Claude Code (map of the code, rules).
