# Going live with real Entra ID — without asking IT

This puts the auth app on Coolify and signs in with the **existing** Entra app registration today. The registration
only knows `https://home.app.journeybooking.eu/auth/entra_id/callback`, which the old Dashboard also uses. The hop
(SPECS.md §24.2) lets both live side by side:

```
browser ─▶ auth.app /auth/entra_id ─▶ Microsoft (redirect_uri = home.app/auth/entra_id/callback, state = tpa.…)
        ◀─ 302 home.app/auth/entra_id/callback?code=…&state=tpa.…
home.app: Traefik rule (deploy/traefik/tourpaq-auth-entra-hop.yaml) sees state=tpa.… ─▶ 302 auth.app/auth/entra_id/callback?<same query>
auth.app verifies state, nonce, PKCE, the ID token and tid ─▶ signed in ─▶ index.app
```

The old Dashboard's own sign-ins carry a state without `tpa.` and never match the rule: **the Dashboard is not
touched and does not need a deploy.** The rule is a Traefik dynamic configuration file in Coolify's proxy (step 3b),
not labels on the container. Deleting the file removes it.

## 0. Check the proxy is Traefik v3

On the Coolify server:

```sh
docker exec coolify-proxy traefik version      # needs 3.x (QueryRegexp)
```

If it says 2.x, stop here: update the proxy in Coolify (Servers → Proxy) first, or use the Dashboard's own forward
(deploying the new Dashboard version, which is the cutover).

## 1. Database

The auth app gets its own role and database, `tourpaq_auth`, on the Tourpaq App Platform's Postgres. The platform
stack must already be deployed on the server, since it owns the Postgres container and the `tourpaq-platform` network.

`bin/create-database` in this repo is self-contained: copy it to the Coolify server and run it there. It finds the
platform's Postgres container (the compose service labelled `postgres`, a label Coolify keeps), creates the role and
database with the platform's isolation rules, tests that isolation, and prints the `DATABASE_URL`:

```sh
scp bin/create-database <server>:
ssh <server>
bash create-database                   # finds the Postgres container itself
bash create-database <container>       # or name it, if it finds none or several (docker ps | grep postgres)
```

It prints:

```
DATABASE_URL=postgres://tourpaq_auth:<password>@postgres:5432/tourpaq_auth
```

**The password is shown once and stored nowhere else**, so paste it straight into the Coolify resource's
environment (step 3). If it is lost: `docker exec -it <container> psql -U postgres -c "ALTER ROLE tourpaq_auth PASSWORD '<new>'"`.

- The script refuses to touch an existing `tourpaq_auth`. To start over, drop both first
  (`DROP DATABASE tourpaq_auth; DROP ROLE tourpaq_auth;`).
- Exit code 2 with a warning means the database works, but the server has not been hardened. The warning prints the
  three commands that fix it.
- There is nothing else to create. Rails makes the tables, including Solid Queue's, on the first deploy
  (`bin/docker-entrypoint` runs `db:prepare` and the seeds).
- The `host` in the URL is `postgres`, the compose service name on the `tourpaq-platform` network, which
  `docker-compose.yaml` joins. It is not a DNS name.

(From a checkout of `../Tourpaq-App-Platform` on the server, `bin/create-app tourpaq_auth` does the same. It only
works where that checkout's `docker compose` can see the platform's running project, which is usually not the case
when Coolify deployed the platform.)

## 2. Repository

Coolify deploys from git, and this repo has no commits or remote yet. Commit it and push it to a new GitHub repository
(e.g. `Tourpaq/Tourpaq-App-Auth`), and give Coolify's GitHub app access to it.

## 3. Coolify resource

New resource → Docker Compose → this repository → `docker-compose.yaml`.

**Domains** on the `web` service, with the container port so Coolify routes to it (Compose mode ignores "Ports
Exposes"):

```
https://auth.app.journeybooking.eu:3050,https://index.app.journeybooking.eu:3050,https://admin.app.journeybooking.eu:3050
```

**Environment variables:**

| Variable | Value |
| --- | --- |
| `SECRET_KEY_BASE` | `openssl rand -hex 64` |
| `DATABASE_URL` | from step 1 |
| `ENTRA_TENANT_ID`, `ENTRA_CLIENT_ID`, `ENTRA_CLIENT_SECRET` | **the same three values the Dashboard uses** (same registration) |
| `ENTRA_REDIRECT_URI` | `https://home.app.journeybooking.eu/auth/entra_id/callback` |
| `OIDC_SIGNING_KEY` | one line: `openssl genrsa 2048 2>/dev/null \| awk 'NF{printf "%s\\n",$0}'` (literal `\n` are accepted) |
| `ENTRA_CLIENT_SECRET_EXPIRES_ON` | the secret's expiry date, if you know it (warning 30 days ahead) |

`APP_URL`, `INDEX_URL` and `ADMIN_URL` default to the three production hosts, so leave them unset.

## 3b. The hop in Coolify's proxy

In Coolify, go to **Servers → (the server) → Proxy → Dynamic Configurations** and add a file named
`tourpaq-auth-entra-hop.yaml` with the content of [`deploy/traefik/tourpaq-auth-entra-hop.yaml`](../deploy/traefik/tourpaq-auth-entra-hop.yaml).
You can also copy that file to `/data/coolify/proxy/dynamic/` on the server. Traefik reloads it within seconds;
nothing needs a redeploy.

It is a file and not labels in `docker-compose.yaml` because Coolify does not unescape `$$` in labels. The redirect's
`${1}` reached Traefik as `$${1}`, the browser landed on `/auth/entra_id/callback?${1}` without Entra's `code` and
`state`, and every sign-in failed as `csrf_detected`. Use the file content exactly as it is, with `${1}` and no doubled `$`.

## 4. NetBird

Give the three hosts the access you want: auth.app and index.app for everyone who uses the apps, and admin.app for the
admins only.

## 5. Deploy and check, before anyone signs in

```sh
curl -s https://auth.app.journeybooking.eu/up                                     # 200
curl -s https://auth.app.journeybooking.eu/.well-known/openid-configuration      # issuer = https://auth.app.journeybooking.eu

# the hop: OUR state is redirected to auth.app with the query unchanged
curl -sI "https://home.app.journeybooking.eu/auth/entra_id/callback?code=x&state=tpa.test" | grep -i -e '^HTTP' -e '^location'
#   HTTP/2 302
#   location: https://auth.app.journeybooking.eu/auth/entra_id/callback?code=x&state=tpa.test

# any other state still reaches the old Dashboard (its own error page for a bogus callback, NOT a redirect to auth.app)
curl -sI "https://home.app.journeybooking.eu/auth/entra_id/callback?code=x&state=abc" | grep -i -e '^HTTP' -e '^location'
```

If the first check does not redirect, or the `location` ends in `?${1}` instead of the query, look at Traefik's logs
(`docker logs coolify-proxy`) for the router `tourpaq-auth-entra-hop` and check the dynamic configuration file
(step 3b). In Coolify the entry point is `https` and the resolver `letsencrypt`. If your proxy names them differently,
adjust those two lines in the file.

## 6. The live test

1. A private window → `https://index.app.journeybooking.eu` → you are sent to auth.app → **Sign in with Microsoft** →
   Microsoft → (home.app, invisible) → back on index.app, signed in.
2. The first sign-in by mwi@, jjr@, mso@ or sar@ **binds the seeded admin** to your Entra account by email (once).
   Anyone else becomes a pending user ("waiting for access").
3. `https://admin.app.journeybooking.eu` → signs in through auth.app (fresh Entra sign-in if the last is older than
   12 h) → the admin UI. A colleague's first sign-in shows up as pending there.
4. **The old Dashboard still signs in as before**: another private window → `https://home.app.journeybooking.eu` →
   Microsoft → Dashboard.
5. The audit log (admin.app → Audit) shows `auth.login`, `user.bound` and `user.created`.

To try an app against the live auth app, create its secret in admin.app (Apps → the app → Clients → new secret) and
set `LOGIN_ISSUER=https://auth.app.journeybooking.eu`, `LOGIN_CLIENT_ID`, `LOGIN_CLIENT_SECRET` in that app.

## If sign-in fails

- **`bad URI (is not URI?): "https://login.microsoftonline.com/<tenant>\"/oauth2/…"`**: a quote is pasted around
  `ENTRA_TENANT_ID` in Coolify. Enter the bare values, with no quotes or spaces, and redeploy. The app now refuses
  to start with a message naming the variable when a tenant id, client id or secret is wrapped like that.
- **`csrf_detected`**: Microsoft's answer reached auth.app (so the hop works), but the browser's session did not hold
  that sign-in attempt. admin.app → Audit → the `auth.login_refused` event's `state_check` says which case it was:
  - `no_session_cookie`: the browser sent no `_tourpaq_auth` cookie. It was blocked or the browser changed, or
    `SECRET_KEY_BASE` changed between starting and finishing, e.g. through a redeploy.
  - `no_attempt_in_session`: the session holds no attempt. The sign-in was started more than 15 minutes earlier, or
    in another browser.
  - `unknown_state`: other attempts are pending, but not this one.

  Before 17 Oct, a second start in the same browser overwrote the first (the auto-submitted page plus a click, or
  two tabs). The auth app now keeps the last three attempts, each usable once.
- **`invalid_client` / `AADSTS7000215`**: the client secret is wrong. Use the secret's *Value*, not its *Secret ID*.
- **`AADSTS50011` (redirect URI mismatch)**: `ENTRA_REDIRECT_URI` is not exactly
  `https://home.app.journeybooking.eu/auth/entra_id/callback`.
- **Back on home.app with a Dashboard error instead of auth.app**: the Traefik rule did not match. Repeat the `curl`
  checks in step 5.
- **`csrf_detected` with `Started GET "/auth/entra_id/callback?${1}"` in the auth app's log** (`state_check`
  `no_state_in_request`): the redirect lost Entra's query because the `$` was escaped. Use the dynamic configuration
  file (step 3b), not Compose labels.

## Rolling back

Delete the `tourpaq-auth-entra-hop.yaml` dynamic configuration (home.app is then exactly the Dashboard again), and stop
or delete the auth app resource in Coolify. Nothing in Entra or the Dashboard was changed.

## Afterwards

When IT has added `https://auth.app.journeybooking.eu/auth/entra_id/callback` to the registration, unset
`ENTRA_REDIRECT_URI`, redeploy, and delete the `tourpaq-auth-entra-hop.yaml` dynamic configuration.
