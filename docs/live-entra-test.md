# Going live with real Entra ID — without asking IT

This puts the auth app on Coolify and signs in with the **existing** Entra app registration today. The registration
only knows `https://home.app.journeybooking.eu/auth/entra_id/callback`, which the old Dashboard also uses. The hop
(SPECS.md §24.2) lets both live side by side:

```
browser ─▶ auth.app /auth/entra_id ─▶ Microsoft (redirect_uri = home.app/auth/entra_id/callback, state = tpa.…)
        ◀─ 302 home.app/auth/entra_id/callback?code=…&state=tpa.…
home.app: Traefik rule (labels on the auth container) sees state=tpa.… ─▶ 302 auth.app/auth/entra_id/callback?<same query>
auth.app verifies state, nonce, PKCE, the ID token and tid ─▶ signed in ─▶ index.app
```

The old Dashboard's own sign-ins carry a state without `tpa.` and never match the rule: **the Dashboard is not
touched and does not need a deploy.** Stopping the auth app removes the rule.

## 0. Check the proxy is Traefik v3

On the Coolify server:

```sh
docker exec coolify-proxy traefik version      # needs 3.x (QueryRegexp)
```

If it says 2.x, stop here: update the proxy in Coolify (Servers → Proxy) first, or use the Dashboard's own forward
(deploying the new Dashboard version, which is the cutover).

## 1. Database

On the platform host:

```sh
bin/create-app tourpaq_auth        # in ../Tourpaq-App-Platform; prints DATABASE_URL (host "postgres")
```

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

If the first check does not redirect, look at Traefik's dashboard/logs for the router `tourpaq-auth-entra-hop`. In
Coolify, the entry point is `https` and the resolver `letsencrypt`; if your proxy names them differently, adjust the
two labels.

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

## Rolling back

Stop or delete the auth app resource in Coolify. The Traefik rule goes with the container, and home.app is exactly
the Dashboard again. Nothing in Entra or the Dashboard was changed.

## Afterwards

When IT has added `https://auth.app.journeybooking.eu/auth/entra_id/callback` to the registration, unset
`ENTRA_REDIRECT_URI`, delete the `traefik.*` labels in `docker-compose.yaml`, and redeploy.
