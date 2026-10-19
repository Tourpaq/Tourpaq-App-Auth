# Tourpaq Auth — specification

The single sign-in and access service for all journeybooking apps. Its issuer is
**https://auth.app.journeybooking.eu**; the index (the apps a person may use, links, docs) is at
**https://index.app.journeybooking.eu** and the administration at **https://admin.app.journeybooking.eu**, all three
the same app (§24.1). People sign in once with their Microsoft Entra ID account; the
auth app knows which apps each person may use and with which role, and every app (the IRM, KPI, Logs
Analyzer, Azure Cost, the index, and those to come) asks it before showing anybody any data.

It does four things:

1. **Signs people in** with Entra ID, and creates an account at their first sign-in.
2. **Lets admins decide access**: which apps each user (or group of users) may use, and with which role.
3. **Is an OpenID Connect provider** for the apps: an app sends the user here to log in and gets back an
   ID token naming the user and their role *in that app*.
4. **Answers the apps' questions**: "does this user still have access, and with which role?" and "is this
   API/MCP token valid, for whom, with which scope?" Personal API/MCP tokens are created and revoked here,
   not in the apps.

This file is the source of truth for scope and decisions. Change it in the same commit as the code that
changes the behaviour. Decisions are recorded with their reason; open items are at the end (§20).

Status: **draft, 16 Oct 2026**, written from the kickoff answers. The foundation and M1 (skeleton, full data
model, Entra sign-in with the fake identity provider, auth and admin sessions, seeds) are built, and the server side
of M2–M5's protocol: the OIDC provider (§7, §7.6), the admin host signing in through it (§11.2), the authorization
API (§8), personal tokens with introspection (§9) and extension refresh tokens (§10), with the recurring jobs (§15).
The auth app's side of M7 is built too: permission-carrying roles with the catalogue push and the per-app
last-administrator guard (§23.2), per-app token scopes (§23.3), the Dashboard's registration and its import (§23.5).
On 17 Oct 2026 the hosts were restructured (§24): the auth, index and admin hosts, the back-channel hosts, the
temporary Entra redirect hop through home.app, and SQLite only on developer machines. The same day the index content
module was built (§24.3): Tourpaq-App-WWW's index merged into the index host, its admin on the admin host, its
extension in `clients/index-extension` signing in through auth.app, and the export/import of WWW's production content.

---

## 1. Decisions

| Topic | Decision |
| --- | --- |
| Identity provider | **Microsoft Entra ID**, one app registration in our own tenant: single tenant, platform *Web*, authorization-code flow with a client secret, delegated `openid profile email` with admin consent, and the **optional ID-token claim `auth_time`** (Token configuration), which a fresh sign-in needs (§3.1). The registration's redirect URI is the Dashboard's `https://home.app.journeybooking.eu/auth/entra_id/callback`, reached through a temporary hop until IT adds `https://auth.app.journeybooking.eu/auth/entra_id/callback` (§24.2). The auth app reads identity from the ID token and **never calls Microsoft Graph** |
| Hosts | One app, **three hosts** (§24.1). **auth.app.journeybooking.eu** is the issuer: Entra sign-in, OIDC, the authorization API, introspection, "waiting for access". **index.app.journeybooking.eu**: the index, profile and personal tokens. **admin.app.journeybooking.eu**: the admin UI, limited to admins (§11.2). Each host has its own host-only session. **The Dashboard stays at home.app.journeybooking.eu**, an ordinary client. Everything is behind NetBird |
| Rollout | **None of the apps are deployed yet**, so each app is built directly against the auth app: no transition periods, no old tokens to keep accepting, no user migration. **The exception is the Dashboard** (Tourpaq-App-Dashboard, in production at home.app), whose users, groups and permissions are migrated into the auth app (§23) |
| How apps integrate | The auth app is an **OIDC provider** (login by redirect, ID token with the app's role claim) **plus an authorization API** that apps call to re-check access during a session and to validate tokens. The IRM and KPI already contain OIDC clients for this (IRM docs/sso.md) |
| Roles | **One role per user per app** by default. Each app is registered with its own ordered role list (IRM: viewer < responder < editor < admin; KPI: viewer < editor < admin). No role means no access. An app may instead declare a **permission catalogue** and **several roles per user**. Its roles are then named permission sets, and the app receives the union of permissions. The Dashboard works this way (§23.2) |
| Groups | Access can be granted to **users and to groups**. A direct user grant overrides the user's groups; otherwise the highest role from their groups wins (§5.3) |
| Revocation | Removing access or disabling a user takes effect in the apps **within about 5 minutes**: apps re-check the authorization API on a short cache, not on every request (§8) |
| Auth sessions | **8 hours idle, 7 days absolute**, after which Entra is asked again (the index host's session has the same limits, counted from the same Entra sign-in). Because there is no Graph access, a user disabled in Entra is noticed at their next Entra sign-in, so within 7 days at most. Removing access in the auth app is the fast path |
| First page | The **index** on index.app (§24.3): the apps the signed-in user has access to, with their role, plus links, docs and search. A new user sees "waiting for access" on auth.app. Admins also get user, group, app and access management on admin.app |
| First admins | The DK Tech four are seeded as admins: mwi@tourpaq.com, jjr@tourpaq.com, mso@tourpaq.com, sar@tourpaq.com. There is one auth-app role, *admin* or not. A console command makes anyone admin on a fresh install |
| Clients in v1 | **Server-side web apps** (confidential OIDC clients) and **browser extensions** (public clients, PKCE, sign-in through `chrome.identity.launchWebAuthFlow`). Mobile apps are later (§17) |
| Personal API/MCP tokens | Issued, listed and revoked **here**. **One app per token**, with a scope from **that app's own scope list** (default `read` / `read_write`; the Dashboard's is `public` / `all`, §23.3). The user picks the lifetime (30, 90 or 365 days, default 90; at most a year). Apps validate a token by calling the auth app (§9). The effective right is the token's scope capped by the user's *current* role in that app |
| Extension credentials | The extension signs in through the auth app and receives an access token for its app plus a rotating refresh token. The app validates that token through the auth app, like a personal token (§10) |
| Stack | Rails 8.1 / Ruby 4.0.7, Hotwire + importmap, plain CSS, Minitest, `bin/docker-dev`. Same conventions and look as the Logs Analyzer, IRM and Azure Cost (dark sidebar, no CSS framework) |
| Database | **SQLite only on developer machines** (development, tests, rehearsals; §24.4). In production the Tourpaq App Platform Postgres via `DATABASE_URL` on the `tourpaq-platform` network: **one database**, `tourpaq_auth`, created with `bin/create-database` on the server (or the platform's `bin/create-app tourpaq_auth`). Solid Queue tables live in it too. Postgres is checked in CI, never locally |
| Hosting | Hetzner via Coolify, Docker Compose resource, port **3050** (Azure Cost 3010, Logs Analyzer 3020, IRM 3030, KPI 3040). **Behind NetBird**, like every app: reachable for everybody on NetBird, which includes the customers and contracted developers who need access (§24.1). Apps on the same Docker network may reach the back-channel through `AUTH_INTERNAL_HOSTS` |

---

## 2. Concepts

- **User**: a person who has signed in with Entra at least once, or whom an admin has added in advance.
  Identified to the apps by a stable **subject** (`sub`) that the auth app assigns.
- **App**: one of our applications, such as the IRM. It has a slug (`irm`), a name, a URL for the
  index, an ordered list of **roles**, and one or more **clients**.
- **Client**: an OAuth/OIDC client of an app. The *web* client is confidential (it has a client secret) and is
  also what the app uses to authenticate when it calls the authorization API. An *extension* client is
  public (PKCE, no secret).
- **Group**: a named set of users, such as DK Tech, RO DevOps or RO Dev.
- **Grant**: *(app, user or group) → role*. A grant to a user may also be **no access**, which overrides
  that user's groups for that app.
- **Effective role**: what a user ends up with in an app after combining grants (§5.3). It is what the ID
  token, the access API and token introspection report.
- **Personal token**: an API/MCP token a user creates for one app.
- **Session**: a signed-in browser at one of the auth app's hosts: the **auth session** on auth.app (the Entra
  sign-in), the index host's and the admin host's own sessions (§24.1). App sessions belong to the apps.

---

## 3. Sign-in with Entra ID

### 3.1 The flow

1. A browser without an auth session, whether it came straight to auth.app or was sent by an app (the index and
   admin hosts are apps here too), goes to the sign-in page on auth.app, which starts `POST /auth/entra_id` (through
   `omniauth-entra-id`; its callback is `/auth/entra_id/callback` on auth.app). The start is POST-only with a CSRF token (§14); when an app sent the browser
   (a pending `/oauth/…` return-to), the page submits itself, so the user does not click.
2. Authorization-code flow to `https://login.microsoftonline.com/<tenant>/v2.0` with `state`, `nonce` and PKCE
   (`S256`), scopes `openid profile email`, `response_mode=query`, and the `redirect_uri` from `ENTRA_REDIRECT_URI`
   (§24.2). PKCE is not required for a confidential client, but it costs nothing and protects the code.
3. `GET /auth/entra_id/callback` on auth.app (directly, or forwarded by the Dashboard from home.app while the hop of
   §24.2 is in use) exchanges the code with the client secret, sending the same `redirect_uri`, and verifies the ID token:
   signature against Entra's JWKS, `iss`, `aud` = our client id, `exp`, `nonce`, and **`tid` equal to
   `ENTRA_TENANT_ID`**.
4. The user is found or created (§3.2), an auth session starts (§3.3), and the browser continues to where it
   was going: the app authorization request that sent it here, or else auth.app's `/`, which sends it on to the index
   (or to "waiting for access").

*Built:* a **fresh sign-in** (an app's `prompt=login` or `max_age`, the admin host's 12 hours, §7.6, §11.2) is
verified, not assumed. The request for it lives in the Rails session (`entra_prompt`, and the time it was asked
for), never in the sign-in form: the Entra strategy sends `prompt=login` from there and ignores `prompt` and `scope`
from the browser. Because whoever holds the browser can still drop `prompt=login` on its way to Microsoft, the
callback takes the time credentials were given from Entra's signed **`auth_time` claim** and refuses the sign-in
(`auth.login_refused`, reason `not_fresh`, "Microsoft did not ask for it") when it is older than the request (5
minutes' clock leeway). Entra sends `auth_time` only as an optional claim of the registration, which the IT request
did not include: the first live admin.app sign-in (18 Oct 2026) was refused as `not_fresh` every time. **Default since
then (`ENTRA_REQUIRE_AUTH_TIME=false`)**: without `auth_time`, freshness counts from the last Entra sign-in the auth
app completed (`Session#credentials_given_at` = `entra_authenticated_at`), and a callback for a requested fresh sign-in
without `auth_time` counts as given now. The cost: a fresh sign-in is then requested (`prompt=login`) but not proven,
because whoever holds the browser could drop `prompt=login` and Microsoft would sign in silently. With the optional
claim added by IT and `ENTRA_REQUIRE_AUTH_TIME=true`, the strict rule above applies again. When Entra does send
`auth_time`, it is always used, whatever the setting.

### 3.2 Who the user is

- The **key is Entra's `oid`** (object id) together with `tid`. It never changes for an account. Email and
  UPN can change, so they are not the key.
- From the ID token, refreshed at every sign-in: `name`, `email` (if absent, `preferred_username`) and
  `preferred_username` (UPN).
- **First sign-in** creates the user with **no access** (*pending*). They see the "waiting for access" page,
  and the admins see them at the top of the users list (§11.2).
- **Pre-created users**: an admin may add a user by email before they have signed in, to give access in
  advance (e.g. RO contractors getting accounts). At that user's first sign-in, a pre-created user that is
  *not yet bound* to an `oid` is matched **once** by email, case-insensitively, and bound to the `oid`.
  After that only the `oid` counts.
- *Built:* an Entra account whose email already belongs to **another, bound** user (same address, different
  `oid`, e.g. a re-created account) is refused (`auth.login_refused`, reason `email_in_use`) rather than
  creating a second user with the same email; an admin sorts it out. When a sign-in brings a changed email that
  another user already has, the old email is kept.
- *Built:* **pending** means active, not an admin, with no direct grant that has a role and no group membership
  (`User.pending`).
- A **disabled** user is refused at sign-in with a plain message. Disabling takes effect everywhere at
  once (§6).

### 3.3 Auth session

- A server-side session row with a random token (`sessions.kind` `home`, a name older than the auth host). The
  cookie holds that token only, signed, `Secure`, `HttpOnly` and `SameSite=Lax`, scoped to
  **auth.app.journeybooking.eu only** and not to the parent domain. Apps, and the index and admin hosts, never see
  or share it.
- *Built:* a session keeps two times: `entra_authenticated_at`, the Entra sign-in behind it (silent or not), from
  which its lifetime counts; and `entra_auth_time`, Entra's `auth_time` (when credentials were last given), which
  alone decides `prompt=login` and `max_age` (§7.6). A silent Entra sign-in therefore never counts as a fresh one,
  and signing out and in again does not reset it.
- **Idle timeout 8 hours** (`SESSION_IDLE_HOURS`) and **absolute lifetime 7 days** (`SESSION_MAX_DAYS`).
  After either, the next request goes through Entra again. If the Microsoft session is still alive this
  is silent; a disabled or deleted Entra account fails there.
- Users see their own sessions (browser, IP, last seen) and can end them. Admins can **sign a user out
  everywhere** (§6).
- **Sign out** (`DELETE /session` on auth.app) ends the auth session. The index host's "Sign out" ends its own
  session and then this one (§11.1). Neither signs the user out of Microsoft.

### 3.4 Local development

The Entra registration has only the production redirect URI. Locally, and in tests, a **fake identity
provider** stands in for Entra. It is available only when `RAILS_ENV` is development or test, and it lets the
developer pick a seeded user. Whether IT also adds `http://auth.localhost:3050/auth/entra_id/callback` (or a
second, dev-only registration) is open (§20).

Locally the three hosts are `http://auth.localhost:3050`, `http://index.localhost:3050` and
`http://admin.localhost:3050` (browsers resolve `*.localhost` to the loopback address), with SQLite (§24.4).

*Built:* `/dev/sign_in` on the auth host (routes drawn only in development and test) lists the users and takes
any email, name and tenant; it builds the same auth hash as the Entra strategy and goes through the same code
(`EntraSignIn`). Its oid is derived from the email, so a pre-created user is bound just as with Entra. Tests use
OmniAuth's test mode with the same hash. The index and admin hosts sign in through the OIDC provider (§11.2,
§24.1), in development too (the fake provider on the auth host stands in for Entra); a dev-only stub at
`admin.localhost:3050/dev/admin_sign_in` remains as a shortcut that starts an admin session for an admin (tests use it
through `sign_in_admin`; the index host has no such stub, tests sign in through the real round trip with
`sign_in_index`).

---

## 4. Users

| Field | Notes |
| --- | --- |
| `id` | Internal |
| `sub` | Public subject for the apps: a random UUID, generated once and never reused. Not the Entra `oid`, so the apps do not depend on Entra identifiers, and pre-created users have a subject before they sign in |
| `entra_oid`, `entra_tid` | Null until the first sign-in for a pre-created user. Unique together |
| `email`, `name`, `upn` | Refreshed from Entra at each sign-in. `email` is unique, case-insensitive |
| `admin` | Admin of the auth app |
| `disabled_at` | Set by an admin |
| `sessions_valid_after` | Bumped by "sign out everywhere". Apps end any of their sessions started before it (§8) |
| `last_login_at`, `created_at` | |

- Users are never deleted while they have audit history. They are disabled.
- **The last active admin cannot be disabled or lose admin.**

---

## 5. Apps, roles, groups and grants

### 5.1 Apps

| Field | Notes |
| --- | --- |
| `slug` | `irm`, `kpi`, `logs`, `azure-cost`, `index` … Lowercase, stable, used in claims and token prefixes |
| `name`, `description`, `icon` | For the index: the "Your apps" card of an app that no index entry stands for (§24.3) |
| `url` | Where the app's card in the index goes |
| `roles` | Ordered list, lowest first, each with a key and a one-line description. At least one role |
| `role_claim` | ID-token claim that carries the role. Default `<slug>_role` with dashes as underscores: `irm_role` and `kpi_role`, which is what those apps already expect (`<slug>_roles` for an app with multiple roles, §23.2). *Built:* a standard claim name (`sub`, `iss`, `aud`, `nonce`, `email`, `name`, `preferred_username`, `sessions_valid_after`, …, `App::RESERVED_CLAIMS`) is refused, and the ID token and userinfo never let the role claim replace another claim |
| `multiple_roles`, `admin_permission`, `token_scopes` | Permission-carrying roles and token scopes, §23.2 and §23.3 (*Built:* default off, none, `read read_write`) |
| `show_in_launcher` | Default on |
| `disabled_at` | A disabled app gets no tokens and its API calls are refused |

- A role still in use by a grant cannot be removed. It must be reassigned first. Roles can be reordered,
  which changes what "highest" means for group grants, so a reorder shows how many users' effective
  roles change before it is saved.
- Apps are created and edited by admins in the UI. The seeds create the apps we know of, with their
  current role lists: IRM, KPI, Logs Analyzer, Azure Cost and the index. Those apps without roles today get
  `viewer < admin` until they say otherwise. *Built:* each app's `url` is the host it runs at, and its web client's
  redirect URI is that host's `/sso/callback`: Azure Cost runs at **azurecost.app.journeybooking.eu** (no dash, as
  the index links to it) although its slug is `azure-cost`; the Dashboard at **home.app.journeybooking.eu** (§24.1);
  the index at **index.app.journeybooking.eu**, which has **no web client** (its host signs in as the internal
  client `index`, §24.1) and keeps the app for its extension's `index-extension` client and `tpx_index_` tokens. Seeds never overwrite, so on an auth app seeded before
  that was corrected, add `https://azurecost.app.journeybooking.eu/sso/callback` to `azure-cost-web` in the admin UI.

### 5.2 Groups

- A name, a description and members. A user can be in any number of groups.
- Seeded: **DK Tech** (the four admins), **RO DevOps**, **RO Dev**, the last two empty.
- Group membership is managed in the auth app only. Entra groups are not read: that would need either the
  `groups` claim or Graph, and the registration asks for neither.

### 5.3 Grants and the effective role

A grant is *(app, subject, role)*, where the subject is a user or a group. For a user and an app:

1. A **direct grant to the user** wins, whatever the groups say. It may lower the role, raise it, or be
   **no access**.
2. Otherwise the **highest role** among the grants to the user's groups, ordered by that app's role list.
3. Otherwise **no access**.
4. A disabled user, or a disabled app, is always **no access**.

The admin UI always shows where an effective role comes from ("responder, from RO Dev"), on the user's
page and on the app's members page.

In an app with multiple roles (§23.2) rules 1 and 2 become a union: the user holds every role of their direct grants
and of their groups' grants, and gets the union of those roles' permissions. A direct **no access** still overrides
everything, and rules 3 and 4 stand.

---

## 6. Disabling and signing out everywhere

| Action | Takes effect |
| --- | --- |
| **Disable user** | Auth, index and admin sessions ended, refresh tokens and personal tokens refused **at once** (§9, §10), access API reports `active: false`. Apps notice within their cache time (§8) |
| **Sign out everywhere** | Auth, index and admin sessions ended, refresh tokens revoked, `sessions_valid_after` bumped. Personal tokens stay valid (they are not sessions); revoking them is separate |
| **Remove access to one app** | The effective role becomes none: the access API says so, that app's tokens are refused, and the extension's refresh tokens for that app are revoked |
| **Lower a role** | Reported by the access API and token introspection from the next call. Apps apply it within their cache time |

Personal tokens are **not deleted** when access is lost. They are refused while the user has no access, and
work again if access comes back before they expire. This keeps an MCP setup from breaking when a role is
changed back and forth.

---

## 7. OIDC provider (how apps sign users in)

### 7.1 Endpoints

| | |
| --- | --- |
| Issuer | `https://auth.app.journeybooking.eu` (exactly `LOGIN_ISSUER` in the apps; `APP_URL` here, never the request's Host header) |
| Discovery | `GET /.well-known/openid-configuration` |
| JWKS | `GET /oauth/jwks`, current and previous signing keys |
| Authorization | `GET /oauth/authorize`: authorization code; `state`, `nonce`; PKCE `S256` (required for public clients, accepted for confidential) |
| Token | `POST /oauth/token`: `authorization_code`, `refresh_token`. Client auth `client_secret_basic` (and `client_secret_post`) |
| UserInfo | `GET /oauth/userinfo` |
| Revocation | `POST /oauth/revoke` (RFC 7009) |
| Introspection | `POST /oauth/introspect` (RFC 7662, §9) |
| End session | `GET /oauth/logout` with `id_token_hint` and a registered `post_logout_redirect_uri` |

The browser endpoints (authorization, end session) answer on auth.app only. The server-to-server endpoints
(discovery, JWKS, token, userinfo, revocation, introspection, and the authorization API of §8) answer on auth.app and
on the **back-channel hosts** of `AUTH_INTERNAL_HOSTS` (§24.1), where nothing else answers. Discovery and every URL in
it name the issuer, whichever host was asked.

The IRM's existing client (IRM docs/sso.md) needs exactly this: discovery with `issuer`, `authorization_endpoint`,
`token_endpoint`, `jwks_uri` and optionally `end_session_endpoint`; code flow with PKCE, `state` and `nonce`;
`client_secret_basic`; and a signed ID token with a `kid` in the header.

### 7.2 Authorizing a user for an app

1. The app redirects to `/oauth/authorize?client_id=…`. Without an auth session the user signs in with Entra
   first (§3), then comes back to this request.
2. **The user must have access to the client's app.** If they do not, the auth app shows its own page,
   "You don't have access to IRM. An admin has been told", with a link to the index. It does not
   bounce an error back to the app. If the request cannot be shown to a person (`prompt=none`), it
   returns `error=access_denied` to the redirect URI instead. Each refusal is audited (`oauth.denied`).
3. There is **no consent screen**. All clients are our own apps.
4. Codes are single use and live 60 seconds. ID tokens live 5 minutes; they are only read at login.

### 7.3 The ID token

Signed **RS256** with a key from `OIDC_SIGNING_KEY`. The `kid` is in the header.

```json
{
  "iss": "https://auth.app.journeybooking.eu",
  "sub": "4c0a5d6e-7b8f-4a21-9c3d-0e1f2a3b4c5d",
  "aud": "irm-web",
  "exp": 1792160700, "iat": 1792160400, "auth_time": 1792158000,
  "nonce": "…",
  "email": "mwi@tourpaq.com",
  "email_verified": true,
  "name": "Mogens Winther",
  "preferred_username": "mwi@tourpaq.com",
  "irm_role": "admin",
  "sessions_valid_after": 1791900000
}
```

- The role claim is the app's `role_claim` with the user's effective role in **that** app only. The token
  says nothing about other apps.
- *Built:* for an app with multiple roles (§23.2) the role claim is the **list** of role names, sorted by name, and
  `<slug>_permissions` (dashes as underscores) the sorted union of their permissions, `*` passed through:
  `"dashboard_roles": ["Finance readers", "Support"], "dashboard_permissions": ["management:finance:view", "module:customers:view"]`.
  Neither may replace another claim (the same reserved-claim backstop as the role claim).
- `email_verified` is `true`: the address comes from our own tenant's directory.
- UserInfo returns the same claims, with the role as of now.

### 7.4 Clients

| Field | Web (confidential) | Extension (public) |
| --- | --- | --- |
| `client_id` | e.g. `irm-web` | e.g. `irm-extension` |
| Secret | Yes, see below | None, PKCE required |
| Redirect URIs | Exact match, e.g. `https://irm.app.journeybooking.eu/sso/callback`; `http://localhost:<port>/…` allowed | `https://<extension-id>.chromiumapp.org/` (and the Edge equivalent) |
| Post-logout URIs | Exact match | — |
| Refresh tokens | No: web apps keep their own sessions and re-check through the access API | Yes (§10) |
| May call the authorization API | Yes | No |

- **Client secrets** are generated by the auth app (`tpcs_` plus 43 characters, so a leaked one is easy to spot),
  shown once, and stored as SHA-256 with a hint. A client can hold
  **two active secrets** at the same time: create the new one, deploy the app with it, then delete the old
  one. Rotation is then zero-downtime, unlike a Postgres password on the platform.
- Each secret has an optional expiry, and the admin UI warns 30 days before it.

### 7.5 Logout

- An app's own logout ends the app's session. It may also send the user to `end_session_endpoint` to end
  the auth session as well. Whether to do so is the app's choice; the IRM's logout stays local today.
- The auth app does **not** send back-channel logout to the apps in v1. `sessions_valid_after` and the
  5-minute access check (§8) cover "sign this person out everywhere".

### 7.6 As built (choices the sections above left open)

Code: `app/controllers/oauth/`, `app/services/oidc/` (`SigningKeys`, `IdToken`, `TokenGrant`, `Introspection`,
`Access`), `app/controllers/concerns/client_authentication.rb`.

- **Signing keys**: the `kid` is the key's RFC 7638 thumbprint, so it needs no configuration and changes exactly
  with the key. Production refuses to boot without a usable `OIDC_SIGNING_KEY` (RSA ≥ 2048 bits);
  development generates `tmp/oidc_dev_signing_key.pem` once; tests generate one per process. Discovery and the
  JWKS are served with `Cache-Control: public, max-age=300`.
- **Authorize**: the client and its redirect URI are checked first; when either is wrong the browser gets our own
  error page and is never redirected. After that, errors go back to the redirect URI with the `state`.
  `response_type=code` only; `scope` must contain `openid` (unknown scopes are dropped; `offline_access` matters only
  for extensions); **`state` and `nonce` are required** on every request (§14). PKCE: `S256` only (`plain` is
  refused); required for extension clients and the internal clients (`admin`, `index`); a web client may omit it, but then must
  not send a `code_verifier`. `prompt=none` and `prompt=login` are understood (`none` cannot be combined).
- **Fresh sign-in**: `prompt=login`, `max_age=0`, and `max_age` older than the auth session's `entra_auth_time`
  (Entra's `auth_time`; unknown counts as too old) send the user through Entra again with `prompt=login`. The
  return-to then carries a signed, 15-minute marker of when that was asked, so the request is satisfied once Entra's
  `auth_time` is newer (5 minutes' leeway; no loop); the callback refuses an Entra sign-in that is not (§3.1). The
  sign-in page no longer bounces a signed-in user to the index while such a fresh sign-in is pending. The code's
  (and ID token's) `auth_time` is the session's `entra_auth_time`, else its `entra_authenticated_at`.
- **Codes**: 43 random characters, SHA-256 stored. A code is claimed (marked used) as soon as its client presents
  it, so a failed exchange also uses it up; a second use is refused and revokes the tokens the first use issued.
  At the exchange the user must still be active with access, and the auth session behind the code must not have
  ended.
- **Token response**: every client gets the ID token. Web and extension clients also get an opaque access token
  `tpx_<slug>_…` (1 hour); a **web client's access token is only good for `/oauth/userinfo`** (introspection answers
  `active: false` for it). Extension clients that asked for `offline_access` get the refresh token. A refresh
  response has no new ID token (it would have no nonce); the extension can call userinfo. Responses carry
  `Cache-Control: no-store`.
- **ID token**: `preferred_username` is the UPN, else the email; `sessions_valid_after` (Unix seconds, rounded up as
  in §8.1) is left out until the user's first "sign out everywhere"; the internal client's token has no role claim.
- **Client authentication**: `client_secret_basic` (id and secret form-encoded, RFC 6749 §2.3.1) or
  `client_secret_post`, never both in one request; extension clients send `client_id` only. The internal clients
  `admin` and `index` are refused over HTTP: their exchange happens only in-process. A disabled client, or a client of a
  disabled app, is refused like an unknown one (`401 invalid_client`).
- **Userinfo**: GET or POST with `Authorization: Bearer`; the token must be live and its user still active with
  access, else `401` with `WWW-Authenticate: Bearer error="invalid_token"`.
- **Revocation**: a client revokes only tokens issued to itself; a refresh token takes its whole chain with it
  (`oauth.revoked`); unknown or foreign tokens are answered 200 as RFC 7009 asks. Personal tokens are revoked by
  their owner on the Tokens page (or by an admin), not here.
- **Logout**: the `id_token_hint` must be signed by us (its expiry is ignored) and names the client; the
  `post_logout_redirect_uri` must be registered for that client (or for `client_id` without a hint), else our error
  page. A hint for the signed-in user ends the auth session at once (`auth.logout`); a hint for somebody else leaves
  the current person signed in. Without a valid hint the user is asked to confirm (a POST with CSRF), and then gets a
  link back to the app rather than a redirect, because the CSP's `form-action` would block a cross-origin redirect
  after a form post.
- **The admin client** (`admin`, §11.2): access means an active admin, so a non-admin is refused at `/oauth/authorize`
  with the "no access" page ("Tourpaq Auth admin") and `oauth.denied`. The "not an admin" page and `admin.denied`
  remain for a session whose user stops being an admin.
- **The index client** (`index`, §24.1): internal like `admin` (no app, no secret, redirect URI
  `INDEX_URL/sso/callback`, post-logout URI `INDEX_URL/signed_out`); access means an active user, pending or not. The
  index host sends a pending user on to "waiting for access" itself. The in-process exchange of an internal client
  also returns when the Entra sign-in behind the auth session was (`entra_authenticated_at`), so the index session's
  7 days count from it.
- *Built (§24.1):* the **back-channel hosts** (`AUTH_INTERNAL_HOSTS`, e.g. `host.docker.internal:3050,auth:3050`; a
  name without a port matches any port) are in `config.hosts`, and a middleware (`InternalHostGate`) answers only
  `/.well-known/openid-configuration`, `/oauth/jwks`, `/oauth/token`, `/oauth/introspect`, `/oauth/revoke`,
  `/oauth/userinfo` and `/api/v1/*` on them (and the health checks); any other path there is 404, before OmniAuth and the
  router. The issuer, the `iss` claim, discovery's URLs, the `WWW-Authenticate` realm and every redirect come from
  `APP_URL`. Behind Coolify `ASSUME_SSL` treats such plain-HTTP container calls as HTTPS, so `FORCE_SSL` does not
  redirect them.

---

## 8. Authorization API (re-checking access)

Apps authenticate with their **web client's** `client_id` and secret (HTTP Basic). A client can only ask
about **its own app**. The API answers on auth.app and on the back-channel hosts (`AUTH_INTERNAL_HOSTS`; the gem's
`LOGIN_INTERNAL_URL`, §24.1).

### 8.1 One user

`GET /api/v1/access/:sub`

```json
{
  "sub": "4c0a5d6e-…",
  "active": true,
  "role": "responder",
  "email": "x@tourpaq.com",
  "name": "…",
  "sessions_valid_after": 1791900000,
  "checked_at": "2026-10-16T09:12:00Z"
}
```

`active` is false when the user is disabled, unknown, or has no access to the app. In that case `role` is
null. `Cache-Control: max-age=300`.

*Built:* the answer is always 200 (an unknown `sub` too). When `active` is false, `email`, `name` and
`sessions_valid_after` are null as well, so an app learns nothing about people who are not its users. For an app with
multiple roles (§23.2) the answer also has `"roles": ["Finance readers", "Support"]` and `"permissions": [...]` (the
sorted union, `*` as is), both `[]` when `active` is false, and `role` is always null. Single-role apps get exactly
the shape above.
`sessions_valid_after` is Unix seconds, **rounded up** to the next whole second (here, in the members list and in the
ID token); `checked_at` ISO 8601 UTC; `Cache-Control: max-age=300, private`.
*Built (17 Oct 2026):* apps keep their session start in whole seconds and end a session that started before
`sessions_valid_after`. A truncated value let a session that started in the same second as the sign out live on
(found in the local stack); rounded up, it ends. A sign-in after the sign out needs a new Entra sign-in, which takes
longer than the rest of that second. `User#sessions_valid_after_epoch`; tests in `test/integration/api/access_test.rb`.

### 8.2 All members of the app

`GET /api/v1/access`. Every user with access to the calling app, with role, email, name and
`sessions_valid_after`. It supports `ETag` / `If-None-Match`. The body is
`{ "app": "irm", "members": [ { "sub", "role", "email", "name", "sessions_valid_after" } ] }` (the Ruby client, §13,
also accepts a bare array).

This is for apps that need people **before** they log in. The IRM must be able to put RO developers on a
schedule before their first IRM login. Such apps sync their user table every few minutes with one call
instead of one per user. Users who drop out of the list have lost access.

*Built:* the ETag is a weak hash of the body; `If-None-Match` with it gives `304`. For an app with multiple roles each
member also has `roles` and `permissions` (as §8.1, `role` null), so the ETag changes when anybody's roles or a role's
permissions change. `Cache-Control: private, no-cache`
(revalidate every time; the ETag makes that cheap). Both calls accept `client_secret_basic` (and
`client_secret_post`), only from **web** clients; each call is counted (`UsageCount` "access") and rate limited to
600 a minute per client.

### 8.3 What apps do with it (the contract)

- **At login**: take the role from the ID token.
- **During a session**: re-check the user (§8.1), or rely on the members sync (§8.2), at most every **5 minutes**
  (`max-age`). On `active: false`, end the session. On a changed role, apply it. On a session that started
  before `sessions_valid_after`, end it.
- **When the auth app cannot be reached**: keep the last known answer for a **grace period** (default 24 hours)
  for users who are already signed in. New logins are impossible anyway. The grace period is a per-app
  setting on the app's side. For the IRM, which must keep paging during an outage, it may be longer (§20).
- The shared Ruby client (§13) implements all of this, so the apps do not each write it.

---

## 9. Personal API/MCP tokens

### 9.1 Creating and holding them

- Created by the user on their **Tokens** page on the index host (`/tokens` on index.app): **app** (only apps they have access to), **name**
  ("Claude Code on my laptop"), **scope** (from the app's own scope list, §23.3: `read` or `read_write` by default),
  **lifetime** (30, 90 or 365 days, default 90).
- The format is `tpa_<app slug>_<43 chars of urlsafe base64 of 32 random bytes>`, e.g. `tpa_irm_k3J…`. The prefix
  makes leaked tokens easy to spot and to search for. Stored as **SHA-256** with a hint (prefix plus the first 6
  characters), **shown once**.
- The user sees their tokens (app, name, scope, created, expires, last used) and revokes them. Admins see and
  revoke everyone's.
- **Reminders**: on the index, 7 days before a token expires. Admins see tokens unused for 90 days flagged.
- A user may hold at most 20 active tokens.

### 9.2 Validating them (apps)

The app receives `Authorization: Bearer tpa_irm_…` and asks the auth app:

`POST /oauth/introspect` with `token=…`, client authentication as in §8.

```json
{
  "active": true,
  "token_type": "personal",
  "client_id": "irm-web",
  "app": "irm",
  "sub": "4c0a5d6e-…",
  "email": "x@tourpaq.com",
  "name": "…",
  "scope": "read_write",
  "role": "responder",
  "exp": 1799936000,
  "token_name": "Claude Code on my laptop"
}
```

- `active: false` (and nothing else) when the token is unknown, expired, revoked, **belongs to another app**,
  or its user is disabled or has no access to the app. An IRM token presented to KPI is refused.
- **The effective right is the scope capped by the role.** A `read_write` token of a user who is now a viewer
  can only read. Each app maps its own roles to what `read_write` allows; the auth app reports both and decides neither.
- Apps cache an answer by the token's SHA-256 for at most **60 seconds**, and never the token itself.
- `last_used_at` is updated by introspection, at most once a minute per token.
- Introspection is rate limited per client.
- *Built:* the caller must be a **web** client. Refresh tokens and web clients' own access tokens are never
  `active`. For an extension token `token_name` is the extension client's name, and its `scope` the app's highest
  token scope (`read_write` by default, the Dashboard's `all`, §23.3). For an app with multiple roles (§23.2) the answer
  also has `roles` and `permissions` (as §8.1), and `role` is null. The answer has
  `Cache-Control: no-store`; a missing `token` is `400 invalid_request`. Each call is counted (`UsageCount`
  "introspect"); the limit is 600 a minute per client.
- *Built:* the **Tokens page** is `/tokens` on the index host (list with hint, create, show once with a copy button,
  revoke). The app list holds only apps the user has access to; at most 10 creations per 10 minutes per user. An
  hourly job records `token.expired` once for every token that ran out unrevoked.

### 9.3 What stays in the apps

Since no app is deployed yet, the apps drop their own personal tokens (the IRM's `ApiToken`, KPI's
`API_TOKEN`/`MCP_TOKEN`, the Logs Analyzer's `MCP_TOKEN`, Azure Cost's `API_TOKENS`) outright, with no transition
period. Only tokens that stand for a **person** move here. Tokens that stand for a **system** stay where they are in
v1: the IRM's integration (webhook) URLs, the watchdog token, the Logs Analyzer's `TRANSFER_TOKEN`, and the
tokens one app uses to call another (KPI → IRM, Logs Analyzer, Azure Cost). Service accounts in the auth app
are a later step (§17, §20).

---

## 10. Browser extensions

1. The extension calls `chrome.identity.launchWebAuthFlow` with `/oauth/authorize` for its public client
   (e.g. `irm-extension`), PKCE `S256`, scope `openid offline_access`, and the redirect URI
   `https://<extension-id>.chromiumapp.org/`.
2. The user signs in at auth.app in that window (silently, if an auth session is alive). Access to the client's app
   is required, as in §7.2.
3. The extension exchanges the code at `/oauth/token` and receives:
   - an **access token** (opaque, `tpx_<slug>_…`, **1 hour**), bound to the app;
   - a **refresh token** (**rotating**: every use returns a new one and retires the old one). It is refused
     after 30 days unused, and in any case after `SESSION_MAX_DAYS`, after which the user signs in again.
4. The extension sends the access token to its app as `Bearer`. The app validates it with **the same
   introspection call** as a personal token (`token_type: "extension"`, scope `read_write`, capped by role).
5. **Reuse of a retired refresh token** revokes the whole chain and is audited (`oauth.refresh_reused`): it
   means the token was copied.
6. Users see their signed-in extensions on their profile and can sign them out. Disabling a user, removing
   their access to the app, or "sign out everywhere" revokes them.

Tokens are kept in `chrome.storage.local`. The extension ID is fixed through the manifest `key`, so the
redirect URI stays stable across installs. *Built:* the IRM's manifest has its key (id
`fejfbgidhcpfhogplgbomjcacgljdjch`), and the seeds give `irm-extension` the redirect URI
`https://fejfbgidhcpfhogplgbomjcacgljdjch.chromiumapp.org/`. The index's extension (`clients/index-extension`, §24.3)
has its key too (id `cicimfifinjjjnagflnckioghehdpogc`), and the seeds give `index-extension` the redirect URI
`https://cicimfifinjjjnagflnckioghehdpogc.chromiumapp.org/` (an auth app seeded before that needs it added on the
client's page: seeds never overwrite).

*Built:* a refresh token expires 30 days after it was issued (each rotation issues a new one) or `SESSION_MAX_DAYS`
after the **Entra sign-in behind the extension's sign-in** (the auth session's `entra_authenticated_at`, not Entra's
`auth_time`, which can be older), whichever
comes first; with the defaults (7 days) the second always wins, so an extension signs in again (silently while the
auth session lives) at least weekly. Without `offline_access` there is no refresh token. Every refresh checks that
the user is still active with access; if not, the chain is revoked. Two concurrent refreshes with the same token:
one wins, the other counts as reuse. "Remove access" revokes the app's OAuth tokens when the admin UI changes a grant
or membership (`AccessChange`), and an hourly sweep (`AccessRevocation`, in `CleanupJob`) catches anything else.

---

## 11. Web UI

Same look as the other apps: dark sidebar, plain CSS, Hotwire, strict CSP (no inline script or style).

### 11.1 Everyone

On the **index host** (index.app, §24.1):

- **The index** (`/`): the apps with access (icon, name, description, role), linking to the apps' URLs, plus the
  index content (§24.3): sections, entries, docs, search.
- **Profile** (`/profile`): name, email (from Entra, read-only), my access per app and where it comes from, sessions,
  signed-in extensions.
- **Tokens** (`/tokens`): §9.1.

On the **auth host** (auth.app): the sign-in page, **"waiting for access"** (`/waiting`) for a signed-in user with no
access yet ("An admin has been told. You can close this page."), the "no access" page of §7.2, and sign out. auth.app's
`/` sends a signed-in user to the index (or to "waiting for access"), anybody else to the sign-in page.

*Built:* the index page lists the user's personal tokens that expire within 7 days at the top (§9.1); the rest of it is
§24.3's front page. An app's card under "Your apps" draws the app's `icon` as an outline icon when it is one of the
known names (`bell`, `chart`, `logs`, `cost`, `home`, `key`, `shield`, `users`, `globe`), as text when it is short (an
emoji), and as the name's initials otherwise. A user who is pending (`User.pending`, §3.2) is sent from any index page
to auth.app's "waiting for access", which sends them back once they have access; a user with nothing to see (a group
without grants, and no entry for everyone) sees "Nothing has been given to you yet". On the profile a user ends any of their own auth-host or index-host sessions (`session.ended`; ending this
browser's index session signs out here) and signs out an extension: an extension is one refresh-token chain, shown by
its current refresh token, and signing it out revokes the whole chain (`oauth.revoked`). The index host's **Sign out**
ends its own session (`auth.logout`, `kind: index`) and then the auth session, through auth.app's `/oauth/logout`
with an `id_token_hint` for the user as client `index` (so no confirmation; the hint carries `sub` and no other
identity claim, since it travels in a URL), back to `/signed_out` on the index host.

### 11.2 Admins (admin.app.journeybooking.eu)

The admin UI lives on its **own host** so that NetBird can limit who reaches it. It is the same Rails app, the
same database and the same deployment. Coolify routes all three domains to the one `web` service.

- **Routing**: the admin routes are constrained to `ADMIN_HOST`, and on the auth and index hosts they do not exist
  (404, not a redirect, so the other hosts do not reveal where the admin lives). The admin host serves only the
  admin UI, its sign-in callback and `/up`. Requests for anything else on it are 404 too.
- **Sign-in**: the admin host is an **OIDC client of the auth app itself** (client `admin`, redirect
  `https://admin.app.journeybooking.eu/sso/callback`). It sends the admin to auth.app's `/oauth/authorize`
  with `max_age` = `ADMIN_REAUTH_HOURS` (12), which forces a fresh Entra sign-in when the last one is older.
  Benefits:
  - the Entra registration keeps its one redirect URI;
  - the admin host has no Entra code of its own;
  - the admin sign-in is tested by the same code as every other app.
  
  The browser needs both the admin host and auth.app, which an admin on NetBird has.
- **Its own session**: the admin host has its own host-only cookie and its own session, ending after
  `ADMIN_SESSION_IDLE_HOURS` (2) idle or 12 hours since the Entra sign-in. Every request also checks that the user is
  still an active admin, so removing admin rights ends the admin session at its next request.
- **Defence in depth**: NetBird is the gate, but the app does not rely on it alone. Admin rights are required on
  every request, and `ADMIN_ALLOWED_CIDRS` (optional, e.g. the NetBird range) makes the app itself refuse admin
  requests from other addresses. The client address is taken from `X-Forwarded-For`, and only the Coolify proxy
  is trusted to set it. *Built:* Rails' `remote_ip` alone would accept `X-Forwarded-For` from any peer, so a
  middleware drops every `X-Forwarded-*` header unless the direct peer is a trusted proxy (`TRUSTED_PROXIES`,
  default loopback and private ranges, where the Docker network is). The compose file publishes no host port, so
  only the proxy reaches the app at all.
- *Built:* the admin host's client `admin` has its own kind, `internal`: it belongs to no app (access means being
  an active admin), has no secret (the admin host is the same process, so its code exchange happens in-process),
  and its redirect URI is derived from `ADMIN_URL`.
- *Built:* the sign-in (`AdminAuthentication#start_admin_sign_in`, `Admin::SsoController#callback`): `state`,
  `nonce` and a PKCE verifier are kept in the admin host's own (host-only) Rails session; the browser goes to
  `/oauth/authorize` with scope `openid email profile` and `max_age` = `ADMIN_REAUTH_HOURS`·3600. The callback checks
  the state (constant time) and that the sign-in is younger than 10 minutes, exchanges the code in-process through
  the same code as `/oauth/token` (`Oidc::TokenGrant`: single use, exact redirect URI, PKCE), verifies the ID token
  against our JWKS (issuer, audience `admin`, expiry, nonce) and requires `auth_time` within `ADMIN_REAUTH_HOURS`; the
  admin session's 12 hours count from that `auth_time`, which is Entra's own `auth_time` (§3.1, §3.3), so only
  credentials really given to Entra within 12 hours open an admin session. Failures show "Sign-in failed" and are audited
  (`auth.login_refused`, `kind: admin`, with the reason).
- **Links**: the index shows admins an "Admin" link to the admin host. Pending-user notifications link there
  too. A non-admin who opens the admin host (if NetBird lets them) sees "not an admin", which is audited
  (`admin.denied`).

What admins manage there:

- **Users**: list with filters (pending, disabled, admins, per app, per group). **Pending users first**, with a
  count in the sidebar. User page: effective access per app (and its source), direct grants, groups,
  sessions, tokens, extensions, and the actions disable/enable, make/remove admin and sign out everywhere.
  **Add user** by email (pre-created, §3.2).
- **Groups**: members, and grants per app.
- **Apps**: details, roles, clients (redirect URIs, secrets with create/rotate/delete), members (effective
  roles and their source), and the token count.
- **Access matrix**: users × apps, showing effective roles, for the "who can see what" question at a glance.
  Exportable as CSV.
- **Audit log**: §12.

**New pending users** show in the admin sidebar count, and optionally post to a Teams channel
(`TEAMS_WEBHOOK_URL`, §20).

*Built:*

- **Pending** is `User.pending` (§3.2), so a pre-created user who has nothing yet is pending too and is listed
  first with the users who signed in and got nothing. The Teams post goes only for users created by their first
  Entra sign-in (bound at creation, not admins): `User` enqueues `PendingUserNotificationJob` after the commit when
  `TEAMS_WEBHOOK_URL` is set. The job posts an Adaptive Card (name, email, an "Open in Tourpaq Admin" button to the
  user's page), skips users who are no longer pending when it runs, and retries a failed post 5 times.
- **Grants** are set from the user's page (per app: a role or "no access", or remove the direct grant) and the
  group's page (per app: a role, or remove). A user who loses access to an app through a grant change or a group
  membership change has that app's extension tokens revoked at once (§6).
- **Last admin**: the signed-in admin is always an active admin, so the only way to lose the last one is to act on
  yourself: the UI refuses to let an admin disable themselves or remove their own admin rights (and the model's
  last-active-admin validation stands behind it).
- **Roles**: a new role is added at the top; the app page has "Higher"/"Lower" per role, which opens a preview of
  the new order listing every user whose effective role changes, with "Save this order". A role used by a grant,
  or an app's only role, cannot be removed.
- **Client secrets**: the plain value is rendered once in the response to the POST (not a redirect, not the flash;
  `Cache-Control: no-store`). Expiry 90 days, 1 year (default), 2 years or never. Secrets expiring within 30 days
  are flagged on the client, the app and the dashboard. The client id and an app's slug cannot change after
  creation; clients and apps can be disabled.
- **Entra secret**: the admin layout shows a banner from 30 days before `ENTRA_CLIENT_SECRET_EXPIRES_ON` (red once
  expired).
- **Access matrix**: active users × active apps; the CSV (`/access.csv`) has `email`, `name`, then per app its
  role and its source (`direct` or the group). Cells a spreadsheet would read as a formula get a leading `'`.
  Downloading it is audited (`access.exported`): it is the list of who can see what.
- **Tokens** (admin): every user's personal tokens, filtered by state (active, unused for 90 days, expiring within
  7 days, revoked, expired) and app; unused ones are flagged; any can be revoked.
- **Audit log**: filtered by user (as actor or subject), app and action (a prefix such as `grant.`), 100 per page.

---

## 12. Audit log

Every sign-in and every state change writes an `AuditEvent`: actor, action (dotted), subject, data (JSON), IP,
user agent and time. These are the IRM's conventions.

- `auth.login`, `auth.login_refused` (disabled, wrong tenant), `auth.logout`, `session.expired`
- `user.created`, `user.precreated`, `user.bound` (pre-created user matched to an `oid`), `user.disabled`,
  `user.enabled`, `user.admin_granted`, `user.admin_revoked`, `user.signed_out_everywhere`
- `group.*`, `group.member_added`, `group.member_removed`
- `grant.created`, `grant.changed`, `grant.removed`, with the before and after effective role of each affected user
- `app.*`, `app.role_*`, `client.created`, `client.secret_created`, `client.secret_deleted`
- *Built, for §23:* `app.catalogue_pushed` (no actor, channel `api`; `count`, `added`, `removed`, `changed` keys and the
  roles' `unknown` keys; only when the catalogue changed, or at the first push); `app.role_changed` with
  `permissions_added` / `permissions_removed` / `unknown`; `grant.created` with `replaced` (the grants an added role or
  "no access" replaced); a multiple-roles app's per-user `before` / `after` is the sorted list of role names or null;
  `import.dashboard` (no actor, channel `console`; source file, its SHA-256 prefix, `exported_at`, `applied`, counts
  of created / changed / skipped per kind, the check's `differences`, `tokens`), and per change the import's
  `user.created` / `user.bound` / `user.precreated` / `app.role_added` / `app.role_changed` with `via: dashboard_import`
  and `grant.created`.
- `oauth.authorized` (which app), `oauth.denied`, `oauth.refresh_reused`
- `token.created`, `token.revoked`, `token.expired`
- *Built, by the web UI:* `session.ended` (a user or an admin ended one session), `oauth.revoked` (an extension
  signed out from the profile or the user's admin page), `group.created`, `group.updated`, `group.deleted`,
  `app.created`, `app.updated`, `app.disabled`, `app.enabled`, `app.role_added`, `app.role_changed`,
  `app.role_removed`, `app.roles_reordered` (with the users whose effective role changed), `client.updated`,
  `client.disabled`, `client.enabled`, `access.exported`. The `grant.*` events have the user or group as subject,
  the app, and `data` = `{ subject, role_before, role_after, users: [ { user_id, email, before, after } ] }`, where a
  grant's role is a key or `"no access"` and a user's role is a key or `null`; `group.member_added` / `_removed`
  carry the member's changed roles per app the group has a grant for.
- *Built, by the protocol:* `oauth.authorized` and `oauth.denied` carry `client_id`; `oauth.revoked` also when an
  extension revokes its own refresh token (RFC 7009); `oauth.refresh_reused` has no actor, the user as subject;
  `auth.logout` from `/oauth/logout` carries `client_id`; `auth.login_refused` with `kind: admin` (or `kind: index`) for a failed admin (or
  index) host sign-in, `auth.login` / `auth.logout` / `session.expired` with `kind: index` for the index host's session (§24.1), and with reason `not_fresh` for an Entra sign-in that did not give the fresh credentials asked for; `session.expired` and `token.expired` also from the hourly jobs (channel `system`, no actor).
- *Built, by the console:* `client.secret_created` from `auth:client_secret` (no actor, channel `console`, §24.4).
- *Built, for the index (§24.3):* `index.<kind>.created` / `.updated` / `.deleted` for every change on the admin host's
  index screens (kinds `entry`, `section`, `access_level`, `login_method`, `doc_section`, `doc`, and `index.site.updated`),
  channel `admin`, the record as subject (an entry tied to an app also carries that app, so the log filters by it);
  `data` has the slug or key and, for an update, `changes` as `{ field: [before, after] }` (a markdown body only as
  `"changed"`; an entry's links and groups as before/after lists). The import writes the same per row with
  `imported: true` and no actor, plus `index.imported` for the run (channel `console`; source file, `exported_at`,
  `applied`, created / changed / skipped counts); a fresh database's seed content writes `index.seeded`.
- **Not** every introspection or access check: those are counted per client and day instead, or the log would
  be nothing else.

The audit log is kept indefinitely. Admins can filter it by user, app and action.

---

## 13. Shared Ruby client (`clients/ruby`)

All of our apps are Rails, and five copies of the same OIDC + introspection code would drift. This repo
therefore ships a small gem, `tourpaq_auth`, that apps include from git:

- **OIDC login**: discovery, PKCE, `state`/`nonce`, ID token verification (JWKS cached, refetched once on an
  unknown `kid`). It is the IRM's `Sso::Client` moved here and generalised.
- **Access check**: the controller concern for §8.3, with the cache, the grace period and `sessions_valid_after`.
- **Members sync**: a job for §8.2.
- **Token check**: a controller concern that introspects a `Bearer` token (§9.2) with a 60-second cache and gives
  the app `current_user` / `scope` / `role`.
- **Test helpers**: a fake auth app (as the IRM's `test/support/sso_helpers.rb`) so apps test without a network.

Configuration in each app: `LOGIN_ISSUER` (`https://auth.app.journeybooking.eu`), `LOGIN_CLIENT_ID`,
`LOGIN_CLIENT_SECRET`, plus optional `LOGIN_ACCESS_CACHE_SECONDS` (300), `LOGIN_GRACE_HOURS` (24) and
`LOGIN_INTERNAL_URL` (the back-channel base URL, §24.1).

As built (clients/ruby/README.md has the details):

- **Distribution**: apps do not take the gem from git. `bin/sync-client <app dir>` copies it to the app's
  `vendor/gems/tourpaq_auth`, used as `gem "tourpaq_auth", path: "vendor/gems/tourpaq_auth"`, so the apps' Docker
  builds need no access to this repository. Its only dependency is `jwt` (~> 2.9); HTTP is `Net::HTTP`.
- **Members sync**: the gem gives `TourpaqAuth::Access.sync_members { |members| … }` (keeps the ETag, yields only on
  a change) rather than a job class: each app writes the few-line job, because only it knows its user table.
- **Token check**: the concern exposes the introspection result (`tourpaq_auth_token`: `sub`, `scope`, `role`, …);
  the app maps `sub` to its `current_user` and caps the scope by its own roles.
- **Role claim**: `LOGIN_ROLE_CLAIM`, by default derived from the client id like §5.1 derives it from the slug
  (`irm-web` → `irm_role`).
- **Outages**: 5xx, 429 and network failures are an outage (grace period). The authorization API and introspection
  are called at the fixed §7.1 paths under `LOGIN_ISSUER` (or `LOGIN_INTERNAL_URL`), not through discovery.
- **Back-channel** (§24.1, gem 0.3.0): with `LOGIN_INTERNAL_URL` set (e.g. `http://auth:3050`, or
  `http://host.docker.internal:3050` in local testing) discovery is fetched there, the discovery document's token,
  JWKS, userinfo, introspection and revocation URLs are moved to that origin, and the access API and the catalogue
  push go there too. The authorization redirect and the end-session URL stay on `LOGIN_ISSUER`, and the discovery
  issuer and every ID token's `iss` are still checked against `LOGIN_ISSUER`. The auth app must list the host in
  `AUTH_INTERNAL_HOSTS`. Apps that vendor the gem take it with `bin/sync-client` and the new version in their
  `Gemfile.lock`.
- **Refusals** are not outages: any other answer (`401 invalid_client` for a disabled app or client or a deleted or
  expired secret, 403, 400, a malformed body) raises `TourpaqAuth::Refused` (a `TourpaqAuth::Error`, with `status`),
  and the access-check concern ends the session at once with the reason `:refused` (no grace period, logged as an
  error). So disabling an app here ends its users' sessions at their next check (about 5 minutes, §1 Revocation).
  The token concern still answers 503 for a refusal (the app cannot check any token).
- **Permission apps** (§23.2, gem 0.2.0): `TourpaqAuth::Login`, `Access::Result`, `Access::Member` and `Tokens::Result`
  have `roles` (role names; `[role]` for a single-role app) and `permissions` (`[]` for a single-role app), with
  `permission?(key)` (true through `*`) and `role?(name)`; `role` is nil when the role claim is a list. The permissions
  claim is `LOGIN_PERMISSIONS_CLAIM`, by default `<app>_permissions` from the client id, and the role list is read from
  `LOGIN_ROLE_CLAIM` or else `<app>_roles`. `TourpaqAuth::Catalogue.push(entries)` sends the catalogue (§23.2). The
  access-check concern calls the optional hook `tourpaq_auth_apply_permissions(roles, permissions, result)` when the
  roles or permissions change (it keeps only a 16-character digest in the session); `require_tourpaq_auth_token scope:
  "all"` requires one of an app's own scopes and `Tokens::Result#scope?(*names)` checks it. The fake provider takes
  `multiple_roles:`, `token_scopes:` and `permissions_claim:`, users with `roles:` / `permissions:` (`set_roles`,
  `set_permissions`), and records catalogue pushes (`catalogue`, `catalogue_pushes`, `catalogue_status`). All of this
  is additive: single-role apps (IRM, index) see no change.
- `TourpaqAuth::Tokens.cached?(token)` tells an app whether an introspection answer is cached, so it can spend a
  per-address budget only on tokens that would reach the auth app (the IRM refuses an address that presented 20
  inactive tokens in a minute, so random tokens cannot use up its 600-a-minute introspection quota here).

---

## 14. Security

- **Secrets never stored in plain text and never logged**: client secrets, tokens, refresh tokens and session
  tokens are stored as SHA-256 and shown once. Filter them from logs: `token`, `client_secret`, `code`,
  `refresh_token`, `Authorization`.
- **Signing keys**: `OIDC_SIGNING_KEY` (RSA 2048+, PEM). Rotation: publish the new key in the JWKS next to the
  old one (`OIDC_PREVIOUS_SIGNING_KEY`), switch signing to it after a day, and remove the old one a day later.
- **Entra client secret expires** (Entra sets at most 24 months). `ENTRA_CLIENT_SECRET_EXPIRES_ON` makes the
  admin UI warn 30 days ahead, and the IRM can alert on it (§15). If it expires, nobody can sign in to any app.
- Exact redirect-URI matching, with no wildcards. PKCE required for public clients. `state`/`nonce` on every
  flow, in both directions.
- Rate limits on sign-in, `/oauth/token`, `/oauth/introspect`, `/api/v1/*` and token creation.
- Strict CSP, security headers, CSRF on all forms, `omniauth-rails_csrf_protection` on the Entra start (POST only).
- The auth session cookie is host-only, so no other app on `*.app.journeybooking.eu` (the Dashboard at home.app
  included) can read it or set one.
- Admin actions happen only on the admin host (§11.2): it is NetBird-limited, has its own session, and needs an
  Entra sign-in younger than 12 hours (by Entra's `auth_time`, §3.1). The auth and index hosts have no admin routes
  at all.
- Each host's cookies are host-only (`home_session` on auth.app, `index_session` on index.app, `admin_session` on
  admin.app, and Rails' own `_tourpaq_auth` on each), so a session on one host is no session on another.
- Everything is behind NetBird (§24.1); the app does not rely on that alone: sessions, admin rights, the optional
  `ADMIN_ALLOWED_CIDRS` and the back-channel hosts' path limit (§7.6) all hold without it. The issuer and every URL the
  app writes come from `APP_URL` / `INDEX_URL` / `ADMIN_URL`, never from the request's Host header.
- The Entra redirect hop (§24.2) is a plain forward: state, nonce and PKCE are verified on auth.app exactly as
  without it, and a `redirect_uri` in the code exchange that differs from the authorization request fails at Entra.
- *Built:* the rate limits (Rails `rate_limit`, counted in the app's memory cache, one Puma process):

  | Endpoint | Limit | Per |
  | --- | --- | --- |
  | Entra callback | 20 / minute | address |
  | `GET /oauth/authorize` | 60 / minute | address |
  | `POST /oauth/token`, `/oauth/revoke` | 60 / minute | claimed client id + address |
  | `/oauth/userinfo` | 120 / minute | address |
  | `/oauth/logout` | 30 / minute | address |
  | `POST /oauth/introspect`, `/api/v1/*` | 600 / minute | authenticated client |
  | Token creation (`POST /tokens` on the index host) | 10 / 10 minutes | user |
  | Admin host `/sso/callback`, index host `/sso/callback` | 20 / minute | address |

  JSON endpoints answer `429` with `Retry-After: 60` (the Ruby client treats it as an outage). The Entra start
  `POST /auth/entra_id` is OmniAuth middleware and has no limit of its own; `/oauth/authorize` and the callback
  around it do.

---

## 15. Availability

The auth app is now in front of every app. If it is down, nobody can **sign in** anywhere, but people already
signed in keep working for the grace period (§8.3), and API tokens keep working for the 60-second cache only.
While the Entra redirect hop of §24.2 is in use, the same is true when the **Dashboard** (home.app) is down: nobody
can complete an Entra sign-in. Therefore:

- `GET /up` does no database query (process liveness). `GET /up/ready` checks the database. Coolify's health
  check uses `/up`.
- The **IRM monitors it**: a heartbeat integration fed by a recurring job here, plus an HTTP check of discovery.
  If the auth app is down, the IRM must still be able to page, which is why the IRM keeps its own device/PIN unlock.
- Backups come from the platform's nightly Postgres dump. A restore must be tested once before go-live (platform README).
- **Break-glass**: `bin/rails "auth:admin[email]"` (make an admin) and `bin/rails "auth:disable[email]"` work from
  the container console without a web session.
- *Built:* the recurring jobs (config/recurring.yml): `HeartbeatJob` every 5 minutes calls `IRM_HEARTBEAT_URL` (GET,
  as the IRM's heartbeat integration takes) only after a database query succeeds, so a missing heartbeat means
  "nobody can sign in"; the URL holds the integration's secret and is never logged. `CleanupJob` hourly (old codes,
  sessions past their limits ended with `session.expired`, the OAuth-token access sweep, dead OAuth tokens and
  usage counts after 400 days) and `TokenExpiryJob` hourly (`token.expired`).

---

## 16. Data model (first cut)

- `users`: id, sub (uuid, unique), entra_oid, entra_tid (unique together, nullable), email (unique, citext-like
  lowercase), name, upn, admin, disabled_at, sessions_valid_after, last_login_at, timestamps
- `sessions`: user_id, token_digest (unique), ip, user_agent, entra_authenticated_at, last_seen_at, created_at, ended_at
- `groups`: name (unique), description. `group_memberships`: group_id, user_id (unique together)
- `apps`: slug (unique), name, description, icon, url, role_claim, show_in_launcher, disabled_at
- `app_roles`: app_id, key, description, position (unique per app, for ordering)
- `grants`: app_id, subject_type (`User` | `Group`), subject_id, app_role_id (null = **no access**, only for users).
  Unique per (app, subject)
- `clients`: app_id, client_id (unique), kind (`web` | `extension`), redirect_uris, post_logout_redirect_uris,
  disabled_at. `client_secrets`: client_id, secret_digest, hint, expires_at, created_at (at most two active per client)
- `authorization_codes`: client_id, user_id, code_digest, redirect_uri, code_challenge, nonce, scope, expires_at, used_at
- `oauth_tokens`: for extensions: client_id, user_id, kind (`access` | `refresh`), token_digest, chain_id,
  replaced_by_id, expires_at, revoked_at, last_used_at
- `personal_tokens`: user_id, app_id, name, token_digest (unique), token_hint, scope, expires_at, last_used_at, revoked_at
- `audit_events`: actor_id, action, subject (polymorphic), data (json), ip, user_agent, created_at
- `usage_counts`: client_id, day, kind (`access`, `introspect`), count
- The index content (§24.3, models `Index::`): `index_sites`, `index_sections` (+ `index_section_groups`),
  `index_entries` (+ `index_entry_groups`, `index_links`), `index_access_levels`, `index_login_methods`,
  `index_doc_sections`, `index_docs`
- Solid Queue tables

**Library choice: no Doorkeeper** (decided 16 Oct 2026). The OIDC provider (§7, §10) is the small subset we need,
written by hand with `jwt` for signing (RS256, `kid`, JWKS). Doorkeeper + doorkeeper-openid_connect would need
patching in exactly the places that matter here: **two active secrets per client** (Doorkeeper has one secret
column per application), **app-bound tokens with our prefixes** (`tpx_<slug>_`, rotating refresh with chain
revocation), and the **in-process admin client** (§11.2) that has no secret and no app. The models above exist
for it; personal tokens (§9) are our own model either way.

*Built, beyond the first cut above:*

- `sessions.kind` (`home` | `index` | `admin`: the auth session, §3.3, and the index and admin hosts' own sessions,
  §24.1, §11.2) in one table (no migration: the column is a string), plus
  `end_reason`, timestamps and `entra_auth_time` (Entra's `auth_time`, §3.3).
- `clients.kind` also takes `internal` (the clients `admin` and `index`, `app_id` NULL; their URIs come from
  `ADMIN_URL` / `INDEX_URL`), and `clients.name`.
- `client_secrets` also: `last_used_at`, `created_by_id`. Secrets are `tpcs_…`.
- `authorization_codes` also: `session_id` (the auth session behind it), `code_challenge_method`, `auth_time`.
- `oauth_tokens` also: `token_hint`, `scope`, `auth_time`; refresh tokens are `tpr_<slug>_…`.
- `personal_tokens` also: `revoked_by_id`.
- `audit_events` also: `app_id` (to filter by app), `channel` (`web`, `admin`, `console`, `system`, `api`) and
  `user_agent`; the IP column is `ip_address`.
- §23 (migration `20261017100001`): `apps.multiple_roles` (boolean, default false), `apps.admin_permission` (string,
  null), `apps.token_scopes` (JSON list, lowest first, default `["read", "read_write"]`), `apps.catalogue_pushed_at`;
  `app_roles.permissions` (JSON list of keys or `*`, default `[]`); `app_permissions`: app_id, key (unique per app),
  label, group_label, position (the pushed catalogue). `grants` is unique per **(app, subject, role)** instead of (app,
  subject); one grant per subject in a single-role app, and a user's "no access" excluding their other grants in an
  app, are model rules (`Grant`).

---

## 17. Not in v1

- **Mobile apps** (the IRM's iOS/Android): they keep the IRM's enrollment links and device key + PIN. Signing
  them in through the auth app (public client, app-claimed redirect URI) comes once the mobile developer has
  started.
- **Service accounts** (non-person tokens for app-to-app calls).
- **Back-channel logout** to the apps.
- **Entra group sync**, or any Graph call.
- **An API/MCP for administering the auth app** itself.
- **Self-service access requests** with approval ("request access to KPI"). The pending page and the admin
  notification cover this for now.

---

## 18. Changes needed in other repositories

Every app: `LOGIN_ISSUER=https://auth.app.journeybooking.eu`, its `LOGIN_CLIENT_ID` and secret, and optionally
`LOGIN_INTERNAL_URL` for the back-channel (§24.1); the gem through `bin/sync-client` (§13).

- **Dashboard** (in production, **stays at home.app.journeybooking.eu**, §24.1): see §23, and the Entra callback
  forward of §24.2 (`GET /auth/entra_id/callback` → `AUTH_ENTRA_CALLBACK_URL`).
- **Tourpaq App Platform**: the `tourpaq_auth` role and database, created with this repo's `bin/create-database` on the server (docs/live-entra-test.md, step 1).
- **Tourpaq-App-WWW** (the index at www.app): its content is exported (`script/index_export.rb`, run on the deployed
  version) and imported into the auth app's index (§24.3), then www.app redirects to index.app and WWW is retired. Its
  round-1 SSO switch is kept in a git stash ("round-1 SSO switch (superseded by the index merge, SPECS §24.3)"); its
  README says the repository is retired after the cutover.
- **IRM**:
  - set `LOGIN_ISSUER=https://auth.app.journeybooking.eu`, `LOGIN_CLIENT_ID=irm-web` and the secret;
    `LOGIN_AUTO_CREATE=true` and `LOGIN_SYNC_ROLES=true`, because the auth app now decides roles;
  - add the access re-check and the members sync (§8), so RO users exist for schedules before they log in;
  - store the `sub` next to the email, so a changed email does not split a user;
  - replace `ApiToken` (`irm_…`) with introspection for the REST API and MCP (§9);
  - move the Chrome extension from enrollment link + PIN to `launchWebAuthFlow` (§10);
  - a heartbeat integration and an HTTP check for the auth app (§15).
- **KPI**: OIDC login with `kpi_role` (its users table already has `sso_subject`); replace `API_TOKEN` / `MCP_TOKEN`
  with introspection, and update the Claude Desktop bundle to take a personal token.
- **Logs Analyzer**: add OIDC login (it has no users today) and replace `MCP_TOKEN` / `KPI_API_TOKEN` (when a person
  uses them) with introspection.
- **Azure Cost**: add OIDC login; replace `API_TOKENS` with introspection.
- **Index**: merged into the auth app (§24.3); its extension moves to `clients/index-extension` and signs in as
  `index-extension`.
- **Ruby client** (§13): used by all of the above.

---

## 19. Deployment and configuration

- Three domains on the one Coolify resource (§24.1): `auth.app.journeybooking.eu` (`APP_URL`, the issuer),
  `index.app.journeybooking.eu` (`INDEX_URL`) and `admin.app.journeybooking.eu` (`ADMIN_URL`, limited in NetBird to the
  admins). All of them are behind NetBird. Rails `config.hosts` allows exactly these three plus the back-channel hosts
  of `AUTH_INTERNAL_HOSTS`. Locally: `auth.localhost:3050`, `index.localhost:3050`, `admin.localhost:3050`.
- `docker-compose.yaml`: one `web` service (port 3050) running Puma with Solid Queue in-process
  (`SOLID_QUEUE_IN_PUMA`). The jobs are small: cleanup, expiry reminders, heartbeat. It joins the
  `tourpaq-platform` network (the production database). Apps that call the back-channel by container name share a
  Docker network with it and list that name in `AUTH_INTERNAL_HOSTS`.
- The web container migrates and seeds on start. The seeds create the admins, groups and known apps; they never
  overwrite data that exists.
- Environment (all in `.env.example`):
  - Rails: `SECRET_KEY_BASE`, `DATABASE_URL` (production only; SQLite otherwise, §24.4)
  - Hosts: `APP_URL=https://auth.app.journeybooking.eu` (the issuer), `INDEX_URL=https://index.app.journeybooking.eu`,
    `AUTH_INTERNAL_HOSTS` (optional, e.g. `auth:3050`)
  - Entra: `ENTRA_TENANT_ID`, `ENTRA_CLIENT_ID`, `ENTRA_CLIENT_SECRET`, `ENTRA_CLIENT_SECRET_EXPIRES_ON`,
    `ENTRA_REDIRECT_URI` (`https://home.app.journeybooking.eu/auth/entra_id/callback` while the hop of §24.2 is in use;
    unset afterwards)
  - OIDC: `OIDC_SIGNING_KEY`, `OIDC_PREVIOUS_SIGNING_KEY` (optional)
  - Admin host: `ADMIN_URL=https://admin.app.journeybooking.eu`, `ADMIN_ALLOWED_CIDRS` (optional),
    `TRUSTED_PROXIES` (optional: the proxies allowed to set `X-Forwarded-*`; default loopback and private ranges)
  - Sessions: `SESSION_IDLE_HOURS` (8), `SESSION_MAX_DAYS` (7), `ADMIN_SESSION_IDLE_HOURS` (2), `ADMIN_REAUTH_HOURS` (12)
  - Optional: `TEAMS_WEBHOOK_URL`, `IRM_HEARTBEAT_URL`
- The three Entra values come from IT and go **only** into Coolify's environment, never into the repository. IT also
  adds the optional claim `auth_time` to the registration's ID token (Token configuration), without which fresh and
  admin sign-ins are refused (§3.1).
- **Go-live order**:
  1. Set up DNS and the NetBird rules for auth.app, index.app and admin.app.
  2. Deploy the Dashboard version with the Entra callback forward (§24.2), and the auth app with
     `ENTRA_REDIRECT_URI=https://home.app.journeybooking.eu/auth/entra_id/callback`.
  3. Sign in as each admin.
  4. Register the apps' clients.
  5. Deploy the apps with their `LOGIN_*` values. No app but the Dashboard is live yet, so there is nothing else to
     switch over; the Dashboard's switch is §23.6.
  6. Later, once IT has added `https://auth.app.journeybooking.eu/auth/entra_id/callback` to the registration: unset
     `ENTRA_REDIRECT_URI` and redeploy. The Dashboard's forward can then go.

---

## 20. Open questions

Answered on 16 Oct 2026, and now in the sections above:

- **Existing tokens**: no app is deployed, so there is no transition (§1, §9.3).
- **Admin exposure**: a separate host, admin.app.journeybooking.eu, limited in NetBird (§11.2).
- **The app at home.app**: the Dashboard; it stays at home.app and is migrated (§23, §24.1, decided 17 Oct 2026).
- **Exposure** (17 Oct 2026): every host is behind NetBird (§24.1).

Still open:

1. **Local development against Entra**: ask IT to add `http://auth.localhost:3050/auth/entra_id/callback` to the
   registration (or make a dev-only registration), or rely on the fake provider only? And when does IT add
   `https://auth.app.journeybooking.eu/auth/entra_id/callback`, which ends the hop through home.app (§24.2)?
2. **Pending-user notification**: post to a Teams channel? Which one?
3. **Grace period during an outage**: 24 hours by default; how long for the IRM?
4. **RO contractors**: members of our tenant, or B2B guests? Guests sign in through our tenant (`tid` matches),
   but their `email` claim may be their own company's address. This decides how admins pre-create them.
5. **Service-to-service tokens** (KPI calling the IRM, Logs Analyzer and Azure Cost): stay as environment tokens, or
   should service accounts in the auth app come into v1?
6. **Who rotates the Entra client secret**, and its expiry date, for `ENTRA_CLIENT_SECRET_EXPIRES_ON`.
7. **Roles for the apps without roles today** (Logs Analyzer, Azure Cost, index): is `viewer < admin` right? (The
   index's web pages need no role, §24.1; its extension's client belongs to the app `index`, so signing the extension
   in needs a role in it, which only DK Tech has from the seeds. Give a group such as RO Dev "Index viewer", or should
   `index-extension` accept every active user like the index host does? The latter is a sign-in rule change, §24.3.)
8. **NetBird and the admin host**: how is admin.app limited, by a DNS record that resolves only inside NetBird or
   by the proxy accepting only the NetBird range? This sets whether `ADMIN_ALLOWED_CIDRS` is needed or only a backstop.

---

## 21. Milestones

| | Scope | Done when |
| --- | --- | --- |
| M1 | Rails skeleton, Entra sign-in, users (pending / pre-created / disabled), auth sessions, seeded admins, audit log, fake IdP for dev/test | An admin signs in with Entra in production; a new colleague's first sign-in shows as pending |
| M2 | OIDC provider for web clients, the admin host signing in through it (§11.2), apps, roles, groups, grants, effective role, launcher, admin UI, access matrix | RO Dev granted IRM responder from admin.app; a member sees the IRM tile with "responder, from RO Dev"; admin.app is unreachable outside NetBird |
| M3 | Client secrets with rotation, authorization API (§8), Ruby client (§13); **the IRM on it** | IRM login through auth.app; removing access ends the IRM session within 5 minutes |
| M4 | Personal tokens and introspection; IRM and KPI REST/MCP switched | Claude Code talks to the IRM MCP with a `tpa_irm_` token; revoking it stops it within a minute |
| M5 | Extension clients, refresh rotation; IRM extension switched | IRM side panel signs in with one click; reuse of an old refresh token revokes it |
| M6 | KPI, Logs Analyzer and Azure Cost switched; signing-key rotation drill; IRM monitoring; restore drill | Every app behind auth.app; a key rotation without anybody being signed out |
| M7 | Permission-carrying roles and per-app token scopes (§23.2, §23.3); Dashboard export/import/verify; the Dashboard switched, staying at home.app (§23) | Import check reports no differences on an export of production imported into a local SQLite auth app (§24.4); the cutover runbook rehearsed |
| M8 | Hosts (§24.1: auth, index, admin, back-channel), the Entra redirect hop (§24.2), the index merged from WWW (§24.3) | An index.app sign-in through auth.app; the Dashboard's forward signs people in; WWW's content imported, www.app redirects |

---

## 22. Testing

- Minitest, run as `bin/docker-dev bin/rails test`, and `bin/ci` (audits, brakeman, tests, seeds), on SQLite (§24.4).
  Several runs side by side each use their own `TEST_DB`.
- A **fake Entra** in tests: discovery, JWKS and a token endpoint signing with a test key. It covers wrong tenant,
  wrong audience, bad nonce, an expired token, a missing `email` claim, and a pre-created user binding once only.
- **Hosts** (tests use `auth.example.com`, `index.example.com`, `admin.example.com` and the back-channel host
  `auth-internal.example.com:3050`): every admin route returns 404 on the auth and index hosts, every index route on the
  auth and admin hosts; the admin and index hosts serve nothing of the auth host; a session cookie of one host is not
  accepted on another; an internal host answers the back-channel endpoints only, with the issuer and every URL from
  `APP_URL`; `max_age` forces Entra again after 12 hours; a demoted admin is out at the next request;
  `ADMIN_ALLOWED_CIDRS` refuses other addresses. The index host's sign-in (`test/integration/index_sso_test.rb`):
  state, PKCE, nonce, a single-use code, 8 h idle and 7 days from the Entra sign-in, a disabled user out at the next
  request, the sign out through `/oauth/logout`.
- **Entra redirect hop** (`test/integration/entra_redirect_hop_test.rb`): the real strategy with `ENTRA_REDIRECT_URI` on
  another host, `response_mode=query`, the same `redirect_uri` in the authorization request and the code exchange;
  state, nonce and PKCE still verified; a code exchange with another `redirect_uri` fails.
- **Effective role** table tests: direct grant vs groups, **no access** overrides, highest wins, disabled user,
  disabled app, and role reordering.
- **OIDC**: the IRM's own SSO tests run against this app locally before M3 is called done. The IRM's client is the
  conformance test that matters. *Built:* the app's own suite also drives the shared Ruby client (`clients/ruby`,
  §13) against the provider (`test/integration/ruby_client_conformance_test.rb`): login, access check, members sync
  with ETag, introspection, and all of it with `LOGIN_INTERNAL_URL` through a back-channel host. The gem's own tests
  run with `clients/ruby/bin/docker-test`.
- **Postgres** (production's engine) is CI's job, never a developer machine's (§24.4): keep SQL portable.
- **Tokens**: a token for another app is refused; the scope is capped by the role; a revoked or expired token is
  refused; refresh reuse revokes the chain; nothing secret appears in `log/test.log` (a test greps it).
- **The index** (§24.3): visibility in the query (`test/models/index/visibility_test.rb`) and on every surface: the
  front page, sections, entry pages, search (HTML and JSON) and `/api/v1/index` (`test/integration/index/`,
  `index_home_test.rb`); the extension's bearer token with the rules of introspection; the admin screens and their audit
  events (`test/integration/admin/index_content_test.rb`); the seed content; the import (`test/services/index/`),
  including a file written by WWW's export script on WWW's HEAD. The extension: `node clients/index-extension/tools/auth_test.mjs`
  (sign-in, refresh rotation, the fetch, with fakes) and `tools/smoke.mjs` (headless Chrome: the fixed id, the panel).

---

## 23. The Dashboard: migration and permission-carrying roles

Decided 16 Oct 2026. To be built after the first build round (milestone M7).

### 23.1 Situation

- **Tourpaq Dashboard** (`../Tourpaq-App-Dashboard`; its own notes call it "Tourpaq Home v2") is the first app we
  built and the only one **in production**. It runs at **home.app.journeybooking.eu** and **stays there** (§24.1):
  the auth app has its own host, auth.app, and the cutover moves no host.
- **The Entra app registration in §1 is the Dashboard's.** The redirect URI `https://home.app.journeybooking.eu/auth/entra_id/callback`
  is its path (Dashboard docs/Entra_SSO_setup.md). The auth app takes over the registration and its three values
  unchanged. Until IT adds auth.app's own callback, the Dashboard forwards that callback to auth.app (§24.2). Users
  are known by the same `oid` from the same tenant, so imported users are **bound already** (§3.2).
- The Dashboard's access model:
  - app-local **groups** hold **permission** strings shaped `<scope>:<id>:<action>` (e.g. `module:customers:view`,
    `management:finance:view`), with `*` as a wildcard;
  - a user's access is the **union** over all their groups;
  - the permission catalogue is derived from the Dashboard's navigation, and unknown permissions are *reported*,
    never ignored;
  - the Administrators group is a system group, and the last administrator cannot lose access.
- Its MCP tokens (`tpq_mcp_…`) belong to a person and carry a confidentiality **capability**: `public`, or `all`
  (which may read internal comments).

### 23.2 Permission-carrying roles (any app may opt in; the Dashboard does)

An app gains three optional settings:

| Setting | Meaning |
| --- | --- |
| `multiple_roles` | A user may hold **several** roles in the app. Their effective roles are the **union** of their direct grants and their groups' grants. A direct **no access** grant still overrides everything. Role order does not matter |
| Permission catalogue | The permissions the app knows: key, label, group label. **Pushed by the app** with `PUT /api/v1/catalogue` (client auth as in §8) at boot or deploy. A push from the app needs no inbound route to the app, and the catalogue cannot drift from the code that checks it |
| Role permissions | Each role is a named set of permission keys from the catalogue, or `*` |

- **Claims, API and introspection** for such an app: the role claim is a **list**, e.g.
  `"dashboard_roles": ["Management", "Finance readers"]`. A second claim `<slug>_permissions` holds the sorted union of
  the roles' permissions, with `*` passed through for the app to interpret. `GET /api/v1/access(/:sub)` and
  `/oauth/introspect` gain `roles` (list) and `permissions` (list). The single `role` stays null for these apps.
- **Unknown permissions are reported, never ignored**, the Dashboard's rule carried over. A role holding a key that
  is not in the current catalogue is flagged on the role, on the app page and on the admin home page. It is still
  sent to the app, which ignores keys it does not check.
- **Last-administrator guard per app**: an app may name an *admin permission* (Dashboard: `admin:access:manage`).
  The auth app refuses a change that would leave no active user holding it, through `*` or the key itself. This
  is the Dashboard's `sole_administrator?` guard, moved here.
- **Admin UI**: the role editor shows the catalogue as checkboxes grouped by the catalogue's group labels, and
  unknown keys in red. The app's members page and the user page show resolved permissions with their source
  ("from Management, via direct grant").
- Apps with a single role per user are unchanged.

*Built* (`App`, `AppRole`, `AppPermission`, `Grant`, `EffectiveRole`, `GrantChange`, `AppAdminGuard`, `CataloguePush`,
`Api::V1::CataloguesController`, `Admin::AppRolesController#edit`):

- **Roles of a multiple-roles app** are names as people write them ("Finance readers"): case and inner spaces kept
  (squeezed), up to 80 printable characters, unique per app without regard to case. Such an app may have **no roles**
  (the Dashboard's come from its import); a single-role app still needs one and keeps lowercase keys. Role order does
  not matter, so the app page hides "Higher"/"Lower" for it. The claim, `roles` and the admin pages list roles sorted
  by name.
- **Permission keys** are letters, digits, `_ . -` separated by colons (`module:customers:view`), at most 100
  characters, or `*`; stored sorted and without duplicates. `*` is kept as the role has it (`["*", "x"]` stays), so the
  union matches the Dashboard's export exactly. Only multiple-roles apps' roles hold permissions.
- **Grants**: a subject holds one grant per role. On the user's and the group's page a multiple-roles app has an "Add"
  select (roles not yet held, plus "no access" for users) and each grant as a removable chip. Choosing "no access"
  replaces the user's role grants in that app, and adding a role replaces a "no access" (`GrantChange.add`, audited as
  `grant.created` with `replaced`). Multiple roles cannot be turned off while a subject holds several roles or a role
  name is not a lowercase key.
- **Effective roles** (`EffectiveRole.for(user, app)`): `held` lists each role with its sources (`direct` first, then
  group names), `permissions` the sorted union, `permission_sources` which roles give each key;
  `EffectiveRole.roles_for` / `.permissions_for` are the same. The members page, the user page (folded per app: "12
  permissions", each with "from Support (via RO Dev)"), the profile, the launcher tile (the roles list), the access
  matrix (a badge per role) and its CSV (`<slug>` = "Finance readers; Support", `<slug> source` = "Finance readers: RO
  Dev; Support: direct", plus a `<slug> permissions` column) show them.
- **The catalogue push**: `PUT /api/v1/catalogue` from any app's web client (HTTP Basic, as §8), body
  `{ "permissions": [ { "key": "module:customers:view", "label": "Customers", "group": "Modules" } ] }` (`group_label`
  is accepted for `group`; label and group optional, at most 200 characters; at most 2000 entries; a body at most 1
  MB). It replaces the catalogue in the given order and answers `200 { "app", "count", "added", "removed", "changed",
  "unknown": [ { "role", "permissions" } ] }`; a malformed body is `400 invalid_request` and changes nothing. Audited
  (`app.catalogue_pushed`) only when something changed, or at the first push, so a push at every boot is not noise.
  It never changes a role, and the last-administrator guard ignores it.
- **Unknown permissions** are flagged once the app has pushed a catalogue (before that there is nothing to compare,
  and the role editor takes keys typed one per line): in red in the role editor (kept ticked until unticked), as a
  pill on the app page's roles table with the list in a box above it, and on the admin home page.
- **The role editor** (`/apps/:app_id/roles/:id/edit`): description; "Everything (*)"; the catalogue as checkboxes in
  one fieldset per group label, in the app's order; the unknown keys; a text box for other keys. Saving is audited
  `app.role_changed` with the keys added and removed.
- **How access works, and standard roles** (`StarterRoles`, `Admin::AppRolesController#starter`): a multiple-roles
  app's page opens with a three-step box (roles are made once; groups are given roles; people are added to groups,
  the everyday task). For an app with a definition in `StarterRoles::DEFINITIONS` (the Dashboard: Admin `*`,
  Management, Staff), a "Standard roles" card lists the ones it does not have yet (by name, without regard to case)
  with their permissions by catalogue label, and one button creates them (`POST /apps/:app_id/roles/starter`, each
  audited `app.role_added` with `via: "starter_roles"`). Keys the pushed catalogue does not know are left out, so a
  starter role is never born with unknown permissions. Existing roles are never changed. While the admin role is
  among the missing, a ticked-by-default box also gives the group DK Tech that role (`GrantChange.add`, audited
  `grant.created`); a refused grant leaves the roles and says why.
- **The last-administrator guard** (`AppAdminGuard.protect`) applies to an active multiple-roles app with an admin
  permission. It refuses a change only when somebody active held the permission before and nobody does after, so an
  app nobody administers yet (the Dashboard before its import) is not blocked. It covers removing or replacing a grant
  (also through a group's deletion), removing a group member, editing a role's permissions, and disabling a user
  (`User#disable!`, the console's `auth:disable` too). Disabling the whole app is not guarded: that is the admin's
  explicit choice about the app. The refusal reads "Dashboard needs at least one active user with admin:access:manage:
  this change would leave nobody with it. Give it to somebody else first."
- **Apps' side** (the gem, §13): `login.roles` / `login.permissions`, `TourpaqAuth::Access.check(sub).permissions`, the
  members sync's `member.permissions`, `TourpaqAuth::Tokens.introspect(token).permissions`, `permission?(key)`, and
  `TourpaqAuth::Catalogue.push(entries)`.

### 23.3 Token scopes per app

- Each app has an ordered **token scope list**: default `read`, `read_write`. The Dashboard's is `public`, `all`.
- The Tokens page offers the scopes of the chosen app. Introspection returns the scope, plus `roles` /
  `permissions` for permission apps. **The app enforces the scope**, as before. For the Dashboard, `all` lets a
  token read internal comments, and only when the user also has the permissions for the data.
- Token prefixes stay `tpa_<slug>_`, so Dashboard tokens look like `tpa_dashboard_…`.

*Built (Dashboard side):* the Dashboard reads the owner's permissions from the introspection answer. Any MCP use
needs the permissions its issue pages need (`module:dashboard:view` or `module:customers:view`, else 403), and `all`
reads internal comments only when the owner also holds the Dashboard permission `mcp:internal_comments:read` (or
`*`); otherwise the token answers as `public` (the scope capped by the role, §9.2). That permission is in the
Dashboard's catalogue, so it is granted in a role here; before the cutover only Dashboard admins could issue `all`
tokens, and anybody with a Dashboard role can create one on the Tokens page.

*Built:* `apps.token_scopes`, set on the app's edit page as a list lowest first ("public all"): distinct names of
lowercase letters, digits and underscores. A scope that active tokens still have cannot be removed. The Tokens page's
scope select follows the chosen app (the `token-scopes` Stimulus controller; the server checks the scope anyway) and
starts at the app's lowest scope, as `PersonalToken.issue!` does without a scope. An extension token's scope is the
app's highest. The app's highest scope is highlighted in the admin token list. `read`/`read_write` read "read
only"/"read and write" on the pages; other scopes as they are.

### 23.4 What moves, what stays

| Moves to the auth app | Stays in the Dashboard |
| --- | --- |
| Entra sign-in and its credentials | Users as **local profiles** (youtrack_login, team, job title, locale, notification settings, tasks), now keyed by the auth `sub` |
| Groups → **Dashboard roles** with the same names, descriptions and permissions | `permit?` / scopes / `verify_authorized`, now reading permissions from the auth app |
| Memberships → **direct user grants** of those roles | The permission catalogue in code (`lib/permissions.rb`, derived from navigation), pushed to auth (§23.2) |
| User and access management screens (users, groups, memberships, user import), and `access:grant_admin` | Everything else under admin: sync, automations, templates, holidays, mail, diagnostics, audit of its own data |
| MCP token issuing and checking | The MCP server itself, now checking `tpa_dashboard_` tokens by introspection |

- The Dashboard's own Entra code and `AUTH_MODE=local` are **removed**. The auth app is the only way in. Its
  break-glass is the console tasks in §15. What stays of Entra in the Dashboard is the temporary forward of
  `GET /auth/entra_id/callback` to auth.app (§24.2): no Entra credentials, no token handling.
- Dashboard roles are **not** turned into auth groups. They are permission sets of one app, and auth groups (DK
  Tech, RO Dev …) stay organisational: "RO Dev → Dashboard role Support" is then one grant.

### 23.5 Data migration

1. **Export** from the running Dashboard: `bin/rails auth:export > dashboard-export.json`, a new task in the
   Dashboard. It writes:
   - users: `entra_oid`, email, name, active;
   - groups: name, description, permissions, system;
   - memberships;
   - each user's resolved permission set, for the check in step 4;
   - the list of live API tokens (owner, name, capability, last used). The list has no digests and is only for
     telling owners.
2. **Import** into the auth app: `bin/rails "auth:import_dashboard[dashboard-export.json]"`. It is a **dry run by
   default** and applies only with `APPLY=1`. It is idempotent and audited (`import.dashboard`), and its report
   lists every create and change.
   - **Users with an `oid`**: matched by `oid`, then by email once, else created **bound** (`entra_oid`, `entra_tid` =
     `ENTRA_TENANT_ID`).
   - **Users without an `oid`** (imported from YouTrack, never signed in): created pre-created only if they hold a
     membership, otherwise skipped and listed.
   - **Inactive users**: get **no Dashboard grants**. They are **not** disabled in the auth app, because the
     Dashboard's "inactive" was about the Dashboard only.
   - **Groups** become roles of app `dashboard` with the same permissions. The Administrators group becomes the
     role `Administrators` with `*`.
   - **Memberships** become direct grants.
   - *Built* (`DashboardImport`, `lib/tasks/auth.rake`); the export it reads is this contract, shared with the
     Dashboard's exporter:

     ```json
     {
       "format": "tourpaq-dashboard-export",
       "version": 1,
       "exported_at": "2026-10-17T09:00:00Z",
       "users":        [ { "id": 12, "entra_oid": "…or null", "email": "x@tourpaq.com", "name": "…", "active": true } ],
       "groups":       [ { "id": 3, "name": "Support", "description": "…", "permissions": ["module:dashboard:view"], "system": false } ],
       "memberships":  [ { "user_id": 12, "group_id": 3 } ],
       "resolved_permissions": [ { "user_id": 12, "email": "x@tourpaq.com", "active": true, "permissions": ["module:customers:view", "…"] } ],
       "api_tokens":   [ { "user_email": "x@tourpaq.com", "name": "Paperclip", "capability": "all", "last_used_at": "…or null", "expires_at": "…" } ]
     }
     ```

     `resolved_permissions` is the sorted union over the user's groups (`*` kept as is); `api_tokens` holds live tokens
     only, never digests or secrets. A file with another `format` or `version` (or without the `users`, `groups` and
     `memberships` lists) is refused, as is an import without the seeded app `dashboard` (multiple roles), or without
     `ENTRA_TENANT_ID` when users have an oid.
   - *Built:* everything runs in **one transaction**; a dry run runs the same code and rolls it back, so its report is
     exactly what `APPLY=1` does. The report lists every create, change and skip (one line each: action, kind, subject,
     detail), a summary per kind with the unchanged count, the **check**, and the tokens whose owners to tell. Rules
     as built: a user matched by oid is left as it is (Entra refreshes name and email at sign-in); an email that belongs
     to **another** bound user is skipped and listed ("sort it out by hand"), as are invalid and repeated emails; a user
     without an oid that already exists by email is used; the Administrators group is recognised by its name or
     `system: true`; an existing role of the same name (without regard to case) is brought in line with the export's
     description and permissions (a change); a membership of a user whose direct grant in the auth app is "no access"
     is skipped (the auth app's decision stands); the import **never removes** a role, user or grant, so a second run
     changes nothing. An existing role's change goes through the last-administrator guard (`AppAdminGuard`, as the role
     editor); a refused change is a skip. **Once an import has been applied, applying one again is refused** unless
     forced (`FORCE=1 APPLY=1`): the export is a snapshot of the cutover, and access is managed here afterwards. Even
     forced (and in a dry run after an applied one), what admins changed after the last applied run stands: a role
     added, edited or removed since (`app.role_*` events not made by the import) is left as it is, and a membership
     whose direct grant was removed or replaced since (`grant.removed`, `grant.created` with `replaced`) is not granted
     again; each is a skip, and the report says an import was already applied. Users it creates bound are not
     announced as pending in Teams. The check compares what the auth app
     now gives every user in `resolved_permissions`: an inactive user must have no access, an active user exactly the
     export's permissions (`*` equal only to `*`; no access counts as an empty set). Audited: each change, and
     `import.dashboard` for the run (also a dry run's is rolled back with it).
3. **Binding in the Dashboard**: the Dashboard adds a `sub` column. At a user's first auth-app login, and in the
   members sync (§8.2), a profile without `sub` is bound **once**, by email. This is the same "adopt by email once"
   rule the Dashboard already uses for YouTrack-imported users. After that only `sub` counts.
4. **Check**: `bin/rails auth:verify_import[dashboard-export.json]` in the Dashboard compares each user's permission
   set from the export with what the auth app now reports (members API). The cutover is not done until it reports
   no differences.
5. **Tokens are reissued.** Old `tpq_mcp_` tokens stop at cutover. The export's token list tells admins whom to
   notify (e.g. the owner of the Paperclip token) **before** the window.

### 23.6 Cutover (a maintenance window of minutes)

No host moves: the Dashboard stays at home.app, the auth app is at auth.app (§24.1).

1. Before: notify token owners. **Rehearse** with real data (§24.4): export from production (§23.5.1), import the
   JSON into a **local SQLite auth app** (`bin/rails "auth:import_dashboard[dashboard-export.json]"`, dry run, then
   `APPLY=1`), run the new Dashboard version locally against it (`LOGIN_ISSUER=http://auth.localhost:3050`, a client
   secret from `bin/rails "auth:client_secret[dashboard-web]"`) and the check (§23.5.4). No database copy is restored
   anywhere.
2. Before the window: deploy the auth app at **auth.app** with the `ENTRA_*` values and
   `ENTRA_REDIRECT_URI=https://home.app.journeybooking.eu/auth/entra_id/callback`. Its Entra sign-in does not complete
   yet (Entra returns to home.app, where the old Dashboard does not forward), and nobody needs it yet.
3. In the window: export from the production Dashboard (§23.5.1); import into the production auth app (dry run, then
   `APPLY=1`); create the `dashboard-web` client's secret from the auth app's container console
   (`FORCE=1 bin/rails "auth:client_secret[dashboard-web]"`: printed once, audited), since nobody can sign in to the
   admin UI before step 4.
4. Deploy the new Dashboard at **home.app** with `LOGIN_ISSUER=https://auth.app.journeybooking.eu`, its client id and
   secret, and the Entra callback forward (`AUTH_ENTRA_CALLBACK_URL`, default
   `https://auth.app.journeybooking.eu/auth/entra_id/callback`). It pushes its catalogue and runs the members sync.
5. Run the check (§23.5.4). An admin and one non-admin sign in to the Dashboard through auth.app (Entra → home.app's
   forward → auth.app → the Dashboard's `/sso/callback`). Give `mcp:internal_comments:read` (in a role) to the owners
   whose old token had capability `all`. The index's "Tourpaq Home" entry keeps https://home.app.journeybooking.eu.
6. Rollback until step 5 passes: put home.app back on the old Dashboard image (its own Entra sign-in, which uses the
   same redirect URI and so needs no forward). The Dashboard's data is untouched by the cutover, apart from the new
   `sub` column, which the old version ignores. The auth app keeps its imported data for the next attempt (a forced
   import, §23.5, brings changes since).
7. Later: once IT has added auth.app's own callback to the registration, unset `ENTRA_REDIRECT_URI` on the auth app;
   the Dashboard's forward is then unused and can be removed.

*Built (auth side of steps 2 and 3):* `ENTRA_REDIRECT_URI` (§24.2) and `auth:client_secret` (§24.4). The seeds register the Dashboard (never overwriting existing rows): slug `dashboard`,
name "Dashboard", url https://home.app.journeybooking.eu, multiple roles, role claim `dashboard_roles`
(permissions claim `dashboard_permissions`), admin permission `admin:access:manage`, token scopes `public` < `all`,
no roles; and its web client `dashboard-web` with the redirect URIs https://home.app.journeybooking.eu/sso/callback
and http://localhost:4013/sso/callback and the post-logout URI https://home.app.journeybooking.eu/. Its secret is
created in the admin UI as for every client, or with `auth:client_secret` as in step 3. An auth app
seeded before 17 Oct 2026 has older Dashboard URLs: set the app's URL and the client's URIs to the ones above in the
admin UI (seeds never overwrite).

### 23.7 Dashboard changes (summary for its own spec and CLAUDE.md)

- An OIDC client of the auth app through the `tourpaq_auth` gem: the `dashboard-web` client, role claim
  `dashboard_roles`, permissions claim `dashboard_permissions`.
- The 5-minute access re-check, and the members sync binding and updating profiles.
- `permit?` reads the permissions from the auth app, cached with the session and refreshed on the re-check. The
  Dashboard's rules stay in force: `verify_authorized`, scopes filter data, never "is admin?".
- Catalogue push at boot.
- MCP via introspection, with capability = token scope capped by the owner's permissions (§23.3), and a per-address
  budget of refused tokens (§13) so random tokens cannot use up its introspection quota.
- Binding by email (§23.5 step 3) skips a deactivated profile that signed in with Entra before the cutover (it may be
  a leaver's, its address reused): it is listed as a conflict for an admin, who reactivates it if it is the same
  person.
- The temporary Entra callback forward (§24.2): `GET /auth/entra_id/callback` → `AUTH_ENTRA_CALLBACK_URL`, query kept,
  302, GET only, not logged with its query.
- Removed: Entra/omniauth, `AUTH_MODE=local`, groups/memberships/user-import/api-token admin screens, the
  `ApiToken` model, and `access:grant_admin`.
- Tests ported, and both CI engines (SQLite and Postgres) still green. The Danish UI and its i18n check are
  unchanged.

---

## 24. Hosts, the index merge and local SQLite (decided 17 Oct 2026, supersedes earlier host decisions)

Where this section disagrees with an earlier one, **this section wins**. The earlier sections are being brought into
line with it.

### 24.1 Hosts

| Host | Serves | Notes |
| --- | --- | --- |
| **auth.app.journeybooking.eu** | Entra sign-in, the OIDC provider (issuer `https://auth.app.journeybooking.eu`), the authorization API, introspection, catalogue push, the "waiting for access" and "no access" pages | **The issuer. Permanent.** `/` sends a signed-in user to index.app. No other issuer name is used anywhere |
| **index.app.journeybooking.eu** | The index (§24.3): the apps a user has access to plus links and services, docs, search; the profile; personal tokens; the index API for the extension | Replaces Tourpaq-App-WWW (www.app.journeybooking.eu) and the launcher of the earlier design |
| **admin.app.journeybooking.eu** | Administration: users, groups, roles, apps, clients, **and the index content** (sections, entries, links, docs, vocabularies) | As §11.2 |
| home.app.journeybooking.eu | **Home (formerly the Dashboard) stays here.** It does not move to another host | An ordinary OIDC client of auth.app |

- **The Dashboard is now called Home** (decided 19 October 2026; its repository is `../Tourpaq-App-Home`). In the auth
  app it is the app `home`: client `home-web`, claims `home_roles` / `home_permissions`, new tokens `tpa_home_…`.
  §23 and the import (`auth:import_dashboard`, the `tourpaq-dashboard-export` format) keep the old name in prose and
  in their contract. *Built:* the seeds create the app as `home`; the migration `RenameDashboardAppToHome` turns an
  existing `dashboard` app into `home` before the seeds run (slug, the role claim if it was the default, the name if
  it was "Dashboard"; roles, grants, catalogue, clients and tokens kept; audited `app.renamed`). Tokens issued as
  `tpa_dashboard_…` keep working: a token is found by its digest, and Home accepts both prefixes. An old
  `dashboard-web` client is left as it is (disable or delete it in admin.app).

- **Everything is behind NetBird.** Mogens controls the NetBird config per host. "Public" in earlier sections means
  "reachable to everyone on NetBird". Customers and contracted developers who need access have NetBird.
  `ADMIN_ALLOWED_CIDRS` stays an optional backstop.
- The **index host** and the **admin host** each sign in through auth.app, using the same in-process OIDC pattern
  as the admin host (internal clients `index` and `admin`). Each has its own host-only session. The index session
  lasts 8 h idle / 7 days, like auth sessions (§3.3); the admin session is as §11.2.
- Server-to-server calls (token, JWKS, introspection, access API, catalogue) go to the issuer's URLs by default.
  `LOGIN_INTERNAL_URL` (gem) and `AUTH_INTERNAL_HOSTS` (auth app) allow those **back-channel** calls to use another
  base URL and host, e.g. a container name on a shared Docker network or `host.docker.internal` in local testing.
  Browser redirects and the `iss` claim always use the issuer.
- Local development uses `auth.localhost:3050`, `index.localhost:3050` and `admin.localhost:3050`. Browsers resolve
  `*.localhost` to the loopback address.

*Built:* `APP_URL`, `INDEX_URL`, `ADMIN_URL` and `AUTH_INTERNAL_HOSTS` (`Rails.configuration.x.auth`, `AuthHosts` in
lib/auth_hosts.rb); `config.hosts` is exactly the three hosts plus the internal ones. Routes per host:
`config/routes/auth.rb`, `oauth.rb` (browser endpoints on the auth host, back-channel on `AuthHosts::BackChannel`),
`api.rb` (back-channel), `index.rb` (controllers in `Index::`, helpers `index_*`), `admin.rb`; each host's routes are
404 on the others. The index host: `IndexAuthentication` (in `Index::BaseController`, layout `index`), the internal
client `index` (§7.6), `Index::SsoController#callback`, Session kind `index`; its `/` is the index (§24.3). auth.app's
`/` sends a signed-in user to index.app, a pending one to `/waiting`. The
back-channel hosts: `InternalHostGate` (§7.6). OmniAuth's `/auth/*` paths are 404 off the auth host in any letter case
(`AuthHostOnly`; OmniAuth itself matches them case-insensitively). Tests: `test/integration/hosts_test.rb`, `index_sso_test.rb`, and the
gem's conformance test through an internal host.

### 24.2 Entra redirect URI: a temporary hop through home.app

The registration has only `https://home.app.journeybooking.eu/auth/entra_id/callback`. Until IT adds
`https://auth.app.journeybooking.eu/auth/entra_id/callback`:

- The auth app sends the Entra `redirect_uri` from **`ENTRA_REDIRECT_URI`** (default: the auth host's own callback),
  in both the authorization request and the code exchange, as Entra requires.
- **The Dashboard forwards** `GET /auth/entra_id/callback` on home.app to the fixed URL in
  `AUTH_ENTRA_CALLBACK_URL` (default `https://auth.app.journeybooking.eu/auth/entra_id/callback`). The query string
  is kept exactly. The forward is a 302, GET only, never to a URL from the request, and not logged with its query
  (code and state are filtered).
- The auth app asks Entra for `response_mode=query`, so the hop is a plain top-level GET. The auth app's
  state/nonce/PKCE cookie (host-only, SameSite=Lax) is then sent when the browser arrives at auth.app.
- **The forward is done by the proxy (decided 17 Oct 2026)**, so the auth app can go live while the *old* Dashboard
  still runs on home.app and still uses the same callback for its own sign-in:
  - the auth app's Entra `state` always starts with **`tpa.`** (`TourpaqEntraId::STATE_PREFIX`; the random part
    follows, and the whole state is still compared against the session);
  - a Traefik router in a dynamic configuration file in Coolify's proxy (`deploy/traefik/tourpaq-auth-entra-hop.yaml`)
    matches `Host(home.app) && Path(/auth/entra_id/callback)
    && QueryRegexp(state, ^tpa\.)` and answers a 302 to auth.app's callback with the query kept (`redirectregex`,
    `service=noop@internal`). It needs Traefik v3. Everything else on home.app, including the old Dashboard's own
    sign-in, never matches and reaches the Dashboard as before;
  - it is a file and not Compose labels: Coolify passed the label's escaped `$${1}` to Traefik unchanged, the redirect
    lost Entra's query (`/auth/entra_id/callback?${1}`), and the first live sign-in failed as `csrf_detected`
    (18 Oct 2026). Deleting the file returns home.app to the Dashboard unchanged;
  - after the Dashboard's cutover, the Dashboard's own forward route stays as a second, redundant path.
- The cost of the proxy forward is small: sign-in depends on Traefik, not on the Dashboard. Removing the hop is one
  IT change (add the auth.app redirect URI), one env change (`ENTRA_REDIRECT_URI` unset) and deleting the dynamic configuration file.
- The go-live steps for a first live Entra test are in `docs/live-entra-test.md`.

*Built (auth side):* `ENTRA_REDIRECT_URI` (`Rails.configuration.x.auth.entra_redirect_uri`, default
`APP_URL/auth/entra_id/callback`) is the strategy's `callback_url`, which omniauth-oauth2 sends as `redirect_uri` in
both requests; `response_mode=query` is added to the authorization request; `/auth/entra_id/callback` on auth.app takes
the forwarded GET (POST stays accepted). Tested end to end in `test/integration/entra_redirect_hop_test.rb`.

### 24.3 The index (Tourpaq-App-WWW merged into the auth app)

- **Content model**, carried over from WWW:
  - sections (WWW "categories") and entries (WWW "apps": name, description, URL, address, status, owner, repo,
    icon, body markdown, links);
  - access levels and login methods (the two pills, gaps shown as `Access?` / `Login?`);
  - docs in doc sections;
  - site settings;
  - search (`/` key, live results).
- **An entry can be tied to an auth App.** It is then shown only to users with access to that app, and shows their
  role(s). Entries that are not apps (servers, Coolify, Grafana, third-party tools) and whole sections have a
  **visibility**: everyone signed in, or only the chosen auth groups. This replaces WWW's everyone/technical
  audience, imported as: everyone → everyone signed in; technical → the groups DK Tech and RO DevOps. Admins
  adjust it later.
- Markdown is always sanitised, as WWW's `Markdown.render` does. The index code lives in its own namespace and
  never touches tokens, keys or sessions other than through the index host's session concern.
- **Extension** ("Tourpaq Index", moved to `clients/index-extension`):
  - signs in with `chrome.identity.launchWebAuthFlow` (client `index-extension`, PKCE, `offline_access`), with a
    fixed extension id through the manifest `key` and that id's redirect URI seeded;
  - fetches `https://index.app.journeybooking.eu/api/v1/index` with its `tpx_index_` bearer token and gets the same
    filtered index as the web page;
  - `/api/v1/index` keeps WWW's response shape (fields may be added, never renamed).
- **Migration of WWW's production content**:
  1. A self-contained export script in Tourpaq-App-WWW that runs on the deployed version (`bin/rails runner`), in the
     format `tourpaq-index-export` v1.
  2. `bin/rails "auth:import_index[path]"` in the auth app: a dry run by default, `APPLY=1` to apply, idempotent.
- **www.app.journeybooking.eu** redirects to index.app (a Coolify redirect) after the cutover. Tourpaq-App-WWW is
  then retired. Its round-1 SSO switch is kept in a git stash, not deleted.

*Built (17 Oct 2026):*

- **Code**: models `Index::Site`, `Index::Section` (+ `Index::SectionGroup`), `Index::Entry` (+ `Index::EntryGroup`,
  `Index::Link`), `Index::AccessLevel`, `Index::LoginMethod`, `Index::DocSection`, `Index::Doc` (app/models/index, tables
  `index_*`, migration `20261017150001`); `Index::Viewer`, `Index::Markdown`, `Index::ExtensionToken`,
  `Index::SeedContent`, `Index::Import` (app/services/index); the index host's `Index::ContentController` and its
  `HomeController`, `SectionsController`, `EntriesController`, `DocsController`, `SearchController`,
  `Api::IndexController`; the admin host's `Admin::IndexContent::*`; `Index::ContentHelper`; `index.css` and
  `index_syntax.css` (WWW's look, classes prefixed `ix-`); Stimulus `index-search`, `index-filter`, `index-copy`,
  `index-links` (WWW's small script, as controllers under the strict CSP).
- **Paths** on the index host are WWW's, so old links work behind the www.app redirect: `/`, `/search` (and
  `/search.json`), `/groups/:slug` (a section), `/apps/:slug` (an entry), `/docs/:section/:slug`, `/docs/:slug`,
  `/api/v1/index`. They are 404 on every other host. On the admin host: `/index` (overview), `/index/entries`,
  `/index/sections`, `/index/access_levels`, `/index/login_methods`, `/index/docs`, `/index/doc_sections`, `/index/site`
  ("Index content" in the admin sidebar).
- **Sections** have a `layout` (`cards`: cards on the front page; `table`: a page of its own with a compact, filterable
  table and a tile on the front page; what WWW's audience did for presentation) and a `visibility` (`everyone`
  signed in, or `groups` with the chosen auth groups). A section restricted to groups with none chosen is seen by
  nobody (the admin overview lists it), and deleting a group takes it out of the choice: visibility only ever narrows.
- **Entries** tied to an auth App (`app_id`) are shown to the users for whom `EffectiveRole` gives access to that app
  (active app, active user, a direct "no access" wins), with their role(s) as the auth app's badges (`effective_role_label`);
  their own visibility is forced to `everyone` and not used. Other entries are `everyone` or `groups`. An entry in a
  section is shown only when the section is too.
- **Enforced in the query** on every surface: `Index::Section.visible_to(viewer)` and `Index::Entry.visible_to(viewer)`
  are SQL subqueries over the viewer's group ids and accessible app ids (`Index::Viewer`); the front page, the menu
  counts, section pages, entry pages (another app's, another group's or a hidden section's entry is a 404, like an
  unknown one), search (`/search` and `/search.json`, `Cache-Control: private, no-store`, so the browser never serves
  one user's index to the next user of the same browser) and the API all go through them. Docs
  have no visibility of their own: they are for everyone signed in.
- **The front page**: the expiring-token reminder; WWW's hero (site title, tagline, search) with an "Admin" link for
  admins; **"Your apps"**: the auth apps the user has access to (shown in the launcher) that no visible entry stands
  for, with their role and its source, so nothing of the old launcher is lost (the app `index` itself is left out); the
  `cards` sections as WWW's cards; entries without a section; tiles into the `table` sections and the docs. The
  sidebar (layouts/index) carries the search box (`/` focuses it, results as you type from `/search.json`), the
  visible sections with their visible entries' count, the docs, and "Updated … ago".
- **Validation and sanitising** as WWW: `Index::URL_FORMAT` (WWW's `App::URL_FORMAT`: http(s) or a site path) on URLs,
  repos and links, the icon rules, a URL or address or link required, unique link labels per entry;
  `Index::Markdown.render` (kramdown GFM + Rouge, `Rails::HTML5::SafeListSanitizer` with WWW's tag and attribute lists,
  heading anchors, `rel="noreferrer"`). Views also pass every editor URL through `safe_index_href` (the same format,
  a second line). The index pages allow `https:` images in their CSP (entry icons are often other sites' favicons, as on
  WWW); scripts and styles stay `'self'`.
- **The admin screens** are WWW's `/admin` on the admin host (admins only, `AdminAuthentication`): the overview with
  counts, **the gaps** (entries without a section, access level or login method; sections and entries seen by
  nobody; apps in the launcher without an entry, with "Add its entry") and recent changes; CRUD for entries (links
  added, removed and ordered in the form; tie to an app; visibility and groups), sections, access levels, login methods,
  docs, doc sections and the site settings. Deleting asks first (`turbo_confirm`). Every change is audited (§12).
  Changing a section's or entry's groups counts as a change (its `updated_at`), which the import relies on.
- **Seeds**: `Index::SeedContent` loads `db/seeds/index` (WWW's `db/seeds/content`, with the changes below) only into
  an empty index (no `index_sites` row), from `db/seeds.rb`, as WWW's `ContentImport` did. Changes: "Tourpaq Home" is
  **"Tourpaq Dashboard"** at `https://home.app.journeybooking.eu` with SSO login, tied to the app `dashboard` (no card
  describes home.app as a launcher any more); "Azure Cost Overview" is tied to `azure-cost`; WWW's technical groups
  are `table` sections for **DK Tech and RO DevOps**; the two getting-started docs describe the merged index.
- **The API** keeps WWW's shape and `version: 1`; added fields: per group `visibility`; per app `app` (slug), `role`,
  `roles`, `visibility`; "Your apps" is the first group (`slug: "your-apps"`, `visibility: "apps"`, login pill
  "Tourpaq sign-in"). It accepts the extension's `Bearer tpx_index_…` (`Index::ExtensionToken`: the token store checked
  in-process through `Oidc::Introspection.extension`, so exactly introspection's rules, and `last_used_at` is recorded)
  or the index host's session; anything else is `401` with `WWW-Authenticate: Bearer` and a JSON body naming where the
  extension signs in (`auth: { issuer, client_id: "index-extension", scope }`); a pending user is `403`. Answers are
  `Cache-Control: private, no-store`; URLs are absolute on `INDEX_URL`.
- **The extension** (`clients/index-extension`, version 2.0.0): WWW's panel, plus `lib/auth.js` (the IRM extension's
  sign-in: launchWebAuthFlow, PKCE S256, state, nonce, `offline_access`, rotating refresh under a Web Lock, revoke at
  sign out) and `lib/index_api.js` (bearer, refresh once on a 401, a 401 after a good refresh forgets the sign-in). It
  reads the issuer from the API's 401 (else `index.` → `auth.` of its server setting), asks for host permission for
  both, keeps no cookies (`credentials: "omit"`), caches the index per user and forgets it at sign out. Its manifest
  `key` fixes the id `cicimfifinjjjnagflnckioghehdpogc` (only the public half was kept), whose redirect URI the seeds
  register. Signing it in needs access to the auth app's app **Index** (§7.2, as every extension client); DK Tech has
  it from the seeds. `bin/package-index-extension` zips it.
- **Migration**: `script/index_export.rb` in Tourpaq-App-WWW (self-contained: its own minimal models, so it runs with
  `bin/rails runner` on the deployed version; output to a file or standard output) writes every content table with
  every column, ids kept and each reference also as its natural key, no other table:

  ```json
  { "format": "tourpaq-index-export", "version": 1, "exported_at": "…", "source": { "app": "Tourpaq-App-WWW", "schema_version": "…", "database": "…" },
    "counts": { "sites": 1, "categories": 6, … },
    "sites": [ … ], "categories": [ … ], "access_levels": [ … ], "login_methods": [ … ],
    "apps":  [ { "id": 3, "slug": "…", …, "category_id": 2, "category_slug": "databases", "access_level_key": "netbird", "login_method_key": null } ],
    "links": [ { …, "app_id": 3, "app_slug": "…" } ], "doc_sections": [ … ], "docs": [ { …, "doc_section_key": "deployment" } ] }
  ```

  `bin/rails "auth:import_index[path]"` (`Index::Import`) is a dry run unless `APPLY=1` (one transaction, rolled back
  for a dry run, so the report is exactly what applying does). It matches by natural key (the site row, section slug,
  vocabulary key, entry slug, link label per entry, doc section key, doc section+slug), creates what is missing and
  brings in line what differs, keeping the export's `created_at` / `updated_at` on new rows; audience everyone →
  `cards` + everyone, technical → `table` + DK Tech and RO DevOps (a missing group is reported and left out); an entry
  whose URL host is an active app's host is tied to that app, and an entry that is already tied is never untied (no
  matching host, or the App disabled, would otherwise show it to everyone signed in; only an admin unties). It never
  deletes: rows only in the auth app are listed
  ("keep"). A row changed in the auth app after the last **applied** import is left as it is (a skip), so it can be
  re-run safely; a row the models refuse is a skip with the reason. Another format or version, or a file without the
  eight lists, is refused. Audited per row and `index.imported`. Production's seeds will have loaded the seed content
  at the first deploy, so the import mostly brings those rows in line with production's (e.g. the Dashboard's card
  takes production's name "Tourpaq Home" back; an admin renames it).
- **Round trip** (tested 17 Oct 2026): the export script ran on WWW's HEAD in a temporary worktree against a scratch
  SQLite database, and its file imported into a scratch auth database (seeded, so on top of the seed content): dry run,
  apply, and a second apply that changed nothing. `test/fixtures/files/www-head-export.json` is such a file, imported
  by `test/services/index/import_test.rb`.

### 24.4 SQLite locally

Development, tests and rehearsals use **SQLite only**. No local Postgres containers and no local Postgres
instructions. Postgres runs in CI (the Dashboard's dual-engine job) and production. The Dashboard cutover is
rehearsed by exporting from production and importing the JSON into a local SQLite auth app, not by restoring a
database copy.

*Built:* `bin/rails "auth:client_secret[client_id]"` creates a new secret for a web client and prints it once with
the `LOGIN_*` lines for the app's environment (audited `client.secret_created`, channel `console`; at most two active
secrets as always; refused in production unless `FORCE=1`), so an app can be run locally against a local auth app.
Several test runs side by side use `TEST_DB=storage/test_<name>.sqlite3 PARALLEL_WORKERS=1`.
