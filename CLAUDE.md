# Tourpaq Auth — notes for Claude Code

Rails 8.1 / Ruby 4.0.7 sign-in and access service for all journeybooking apps: Entra ID sign-in, users,
groups, apps with ordered roles, grants, an OIDC provider for the apps, an authorization API, personal API/MCP
tokens. **SPECS.md is the source of truth**: read the relevant section before changing behaviour, and update it in
the same commit when behaviour changes (deviations are recorded there as *Built:* notes). README.md covers
running and deploying.

## Working on the code
- The host Ruby is not used: run everything through `bin/docker-dev …` (image `auth-dev`, gems in the
  `auth_bundle` volume). Tests: `bin/docker-dev bin/rails test`; full CI (audits, brakeman, tests, seeds):
  `bin/docker-dev bin/ci`.
- **Several agents may work here at once: use your own test database**:
  `TEST_DB=storage/test_<yourname>.sqlite3 PARALLEL_WORKERS=1 bin/docker-dev bin/rails test`. Never touch
  `storage/development.sqlite3` or anybody's `.env` from a test run.
- **SQLite only on developer machines** (SPECS.md §24.4): never start a local Postgres or write local-Postgres
  instructions. Postgres is production's engine and CI's job; keep SQL portable.
- Dev server: `bin/docker-dev` → auth http://auth.localhost:3050, index http://index.localhost:3050, admin
  http://admin.localhost:3050. Solid Queue runs inside Puma (SOLID_QUEUE_IN_PUMA), no separate worker.
- Sign in locally with the **fake identity provider**: http://auth.localhost:3050/dev/sign_in (development and test
  only). The index and admin hosts sign in through the app's own OIDC provider (they send you to the auth host
  first); http://admin.localhost:3050/dev/admin_sign_in is a dev-only shortcut (the index host has none).
- Running an app locally against this one: `bin/docker-dev bin/rails "auth:client_secret[irm-web]"` prints a new
  secret once with the `LOGIN_*` lines (audited; refused in production unless `FORCE=1`).
- Look and feel follows ../Tourpaq-App-IRM (plain CSS in app/assets/stylesheets/application.css, dark sidebar
  layout, no CSS framework), Hotwire + importmap.

## Three hosts, one app (SPECS.md §24)
- AUTH (`APP_URL`, **the issuer**, `https://auth.app.journeybooking.eu`; tests auth.example.com, where every
  integration test starts): Entra sign-in, OIDC, the API, introspection, catalogue, `/waiting`, "no access", sign out;
  `/` redirects a signed-in user to the index. INDEX (`INDEX_URL`; tests index.example.com): the index (§24.3: WWW's front page, sections,
  entries, docs, search, `/api/v1/index` for the extension), profile, tokens. ADMIN (`ADMIN_URL`; tests admin.example.com): the admin UI only (with the index content under `/index`). Back-channel
  hosts (`AUTH_INTERNAL_HOSTS`; tests auth-internal.example.com:3050): discovery, JWKS, /oauth/token, introspect,
  revoke, userinfo and /api/v1/* only (`InternalHostGate`). `AuthHosts` (lib/auth_hosts.rb) knows them all;
  `config.hosts` is exactly the three plus the internal ones.
- **The issuer and every URL the app writes come from APP_URL / INDEX_URL / ADMIN_URL, never from the Host header.**
  There is no other issuer name; `home.app` is the Dashboard's host (and the temporary Entra redirect hop's, §24.2) only.
- Routes are split per host with `draw` (config/routes.rb): `auth.rb` (auth host), `oauth.rb` (browser endpoints on
  the auth host, back-channel on `AuthHosts::BackChannel`), `api.rb` (back-channel), `index.rb` (index host, paths at
  its root, controllers in `Index::`, helpers `index_*`), `admin.rb` (admin host, controllers in `Admin::`, helpers
  `admin_*`), `dev.rb` (development/test only). A route on one host is a 404 on the others; only `/up` and
  `/up/ready` answer anywhere.
- Each host has its own host-only cookies: `home_session` (auth host), `index_session`, `admin_session` hold a
  Session token (kind `home` / `index` / `admin`; "home" is the auth session's older name), plus Rails' own
  `_tourpaq_auth` cookie session per host.
- Entra: `ENTRA_REDIRECT_URI` (default the auth host's callback) is the redirect_uri of the authorization request
  and the code exchange, with `response_mode=query`, so the Dashboard can forward home.app's callback (§24.2).

## Map
- Models (app/models): `User` (sub UUID, Entra oid+tid, admin, disabled_at, sessions_valid_after; `disable!`,
  `enable!`, `make_admin!`, `remove_admin!`, `sign_out_everywhere!` audit themselves; last-active-admin
  validation; `User.pending`), `Session` (`start!`, `find_by_plain`, idle/absolute expiry per kind, scopes `home` / `index_host` / `admin`,
  `host_label`), `Group`,
  `GroupMembership`, `App` (ordered `roles`, `role_claim`, `rank`, `reorder_roles!`), `AppRole`, `Grant` (app_role
  nil = no access, users only), `Client` (web / extension / internal; `generate_secret!`, `authenticate_secret`,
  `Client.authenticate`, exact redirect URIs, `Client.admin_client` / `Client.index_client`, internal URIs from
  ADMIN_URL / INDEX_URL), `ClientSecret`, `AuthorizationCode`,
  `OauthToken`, `PersonalToken` (`issue!` → plain `tpa_<slug>_…`, `find_by_plain`, `usable?`, `revoke!`),
  `UsageCount.increment!`, `AuditEvent.record`, `Current`.
- `app/models/concerns/hashed_token.rb`: SHA-256 digest + hint, `assign_new_token(prefix:)`, `find_by_token`.
- `app/services/effective_role.rb`: §5.3 — `EffectiveRole.for(user, app)`, `.apps_for(user)`, `.members_of(app)`,
  results with `role`, `role_key`, `source` ("direct" or the group's name), `to_s` ("responder, from RO Dev"); for a
  multiple-roles app (§23.2) `held` (roles with sources), `role_keys`, `permissions`, `permission_sources`,
  `audit_value`, and `.roles_for` / `.permissions_for`.
- Permission-carrying roles and token scopes (§23.2, §23.3): `App#multiple_roles?`, `#permissions_claim`,
  `#admin_permission`, `#catalogue` (`AppPermission`), `#unknown_permissions`, `#token_scopes`; `AppRole#permissions`;
  `GrantChange.set`/`.add`/`.remove` (the only way to change grants; several per subject in a multiple-roles app);
  `AppAdminGuard.protect(apps) { … }` (per-app last-administrator guard: wrap every change that can take a
  permission away); `CataloguePush` behind `PUT /api/v1/catalogue` (`Api::V1::CataloguesController`); the role
  editor `Admin::AppRolesController#edit`; `DashboardImport` behind `auth:import_dashboard` (§23.5). Test helpers:
  `test/support/dashboard_helpers.rb` (`create_dashboard_app`, `grant_dashboard`); export fixtures in
  `test/fixtures/files/`. In integration tests do not name an instance variable `@app` (it is the Rack app).
- Sign-in: `lib/omniauth/strategies/tourpaq_entra_id.rb` (omniauth-entra-id + PKCE + nonce + JWKS signature +
  tenant check via `lib/omniauth/entra_id_token.rb`), `config/initializers/omniauth.rb`,
  `OmniauthCallbacksController`, `app/services/entra_sign_in.rb` (find by oid / bind pre-created once / create
  pending / refuse), `app/services/fake_identity.rb`, `Dev::SignInsController`.
- Controller concerns: `Authentication` (auth host; in ApplicationController), `IndexAuthentication` (index host; in
  `Index::BaseController`, layout `index`: `current_user`, `require_index_sign_in`, `complete_index_sign_in`) and
  `AdminAuthentication` (admin; in `Admin::BaseController`). Their headers list the interface. The index and admin
  hosts sign in as internal OIDC clients (`start_index_sign_in` / `start_admin_sign_in` → the auth host's
  /oauth/authorize; `Index::SsoController#callback` / `Admin::SsoController#callback` exchange in-process and verify
  the ID token). `RootController` (auth `/`) and `WaitingController` (`/waiting`) on the auth host;
  `Index::HomeController` (the index's front page), `Index::ProfileController`, `Index::TokensController`,
  `Index::SessionsController` (sign out through /oauth/logout, `/signed_out`).
- Protocol (SPECS.md §7–§10): `app/controllers/oauth/` (discovery, JWKS, authorize, token, userinfo, revoke,
  introspect, logout), `app/controllers/api/v1/access_controller.rb` (§8), `TokensController` (/tokens, §9.1),
  `app/services/oidc/` (`SigningKeys`, `IdToken`, `TokenGrant`, `Introspection`, `Access`),
  `ClientAuthentication` (client_secret_basic/post, public clients), `RateLimitStore`, `Admin::SsoController` +
  `AdminAuthentication#start_admin_sign_in` (admin host as client "admin"). Jobs: `CleanupJob`, `TokenExpiryJob`,
  `HeartbeatJob`. Test helpers: `test/support/oidc_helpers.rb` (`oidc_login`, `pkce_pair`, `authorize_path_for`,
  `code_from`, `basic_auth`, `introspect`, `verify_id_token`, `assert_admin_sign_in_started`).
- The index content (SPECS.md §24.3, WWW merged): models in app/models/index (`Index::Site`, `Section` (+`SectionGroup`),
  `Entry` (+`EntryGroup`, `Link`), `AccessLevel`, `LoginMethod`, `DocSection`, `Doc`; tables `index_*`; `Index::URL_FORMAT`),
  services in app/services/index (`Viewer`: the viewer's group ids and accessible apps; `Markdown`: sanitised GFM;
  `ExtensionToken`: tpx_index_ checked in-process through `Oidc::Introspection.extension`; `SeedContent`: db/seeds/index into
  an empty index; `Import`: `auth:import_index`). Index host: `Index::ContentController` (base of `HomeController`,
  `SectionsController`, `EntriesController`, `DocsController`, `SearchController`; CSP allows https images) and
  `Index::Api::IndexController` (`/api/v1/index`: Bearer or the index session); the sidebar is
  `app/views/index/shared/_nav.html.erb`. Admin host: `Admin::IndexContent::*` under `/index` (helpers `admin_index_*`).
  Helpers `Index::ContentHelper` (`index_icon`, pills, `index_role`, `safe_index_href`). CSS `index.css` (classes `ix-`),
  `index_syntax.css`; Stimulus `index-search`, `index-filter`, `index-copy`, `index-links`. Extension:
  `clients/index-extension` (Node tests in its `tools/`). Fixtures in test/fixtures/index (sections apps / databases,
  entries salesview / sql_bravo / irm tied to the IRM app).
- Middleware (lib/rack_ext): `AuthHostOnly` (OmniAuth's /auth/* only on the auth host), `InternalHostGate` (only the
  back-channel on AUTH_INTERNAL_HOSTS),
  `TrustedForwardedHeaders` (X-Forwarded-* only from trusted proxies).
- `config/initializers/auth.rb`: every env tunable in `Rails.configuration.x.auth` (tests ignore the env).
- `lib/tasks/auth.rake`: `auth:admin[email]`, `auth:disable[email]` (break-glass), `auth:client_secret[client_id]`
  (local testing), `auth:import_index[path]` (§24.3; WWW's tourpaq-index-export, dry run unless `APPLY=1`), `auth:import_dashboard[path]`
  (§23.5; dry run unless `APPLY=1`; once applied, again only with `FORCE=1`, keeping later admin changes). `app/jobs/cleanup_job.rb`
  (hourly, config/recurring.yml).
- Tests: `test/support/sign_in_helpers.rb` (`sign_in_as(user)` on the auth host, `sign_in_with_entra(email:, …)`,
  `sign_in_index(user, path: "/", sign_in: true)` through the real index OIDC round trip, `sign_in_admin(user)`,
  `sign_out`), `host_helpers.rb` (`on_auth_host!`, `on_index_host!`, `on_admin_host!`, `on_internal_host!`,
  `signed_cookie`, `cookie_header`), `entra_helpers.rb` (`mock_entra`, `mock_entra_failure`, `FakeEntraKeys`),
  `config_helpers.rb` (`with_auth_config`, `assert_same_value`). Fixtures: users mwi, jjr (admins), alice (RO Dev
  → IRM responder), bob (pending), carol (pre-created, unbound), dave_disabled; groups dk_tech, ro_devops,
  ro_dev; apps irm, kpi with roles irm_viewer…irm_admin, kpi_viewer…kpi_admin; clients irm_web, irm_extension,
  kpi_web, admin, index.

## Rules
- **One database.** Solid Queue's tables are a migration in the app database. SQLite in dev/test, Postgres in
  production: keep SQL portable (no SQLite- or Postgres-only functions).
- Secrets and tokens are only ever stored as SHA-256 (with a hint) and shown once. Never log them; the filter
  list is in config/initializers/filter_parameter_logging.rb and a test checks the log.
- Every state change writes an `AuditEvent` with a dotted action name (SPECS.md §12). The `User` and token
  domain methods audit themselves; don't audit twice.
- Strict CSP: no inline `<script>` or `style=""`; behaviour goes in Stimulus controllers, styling in the stylesheet.
- Timestamps are UTC in storage; display Europe/Copenhagen (`local_time`, `relative_time`).
- Admin pages live only on the admin host, under `Admin::BaseController`; index pages only on the index host, under
  `Index::BaseController`. Never add an admin or index route to the auth host, and never answer anything but the
  back-channel on an internal host.
- Real Entra credentials are not available: everything must work and be tested with the fake identity provider.
- **The index** (§24.3): visibility is enforced in the query on every surface (`Index::Section.visible_to`,
  `Index::Entry.visible_to`): never filter in Ruby after loading, never add a surface that skips them. Editor URLs pass
  `Index::URL_FORMAT` and markdown always goes through `Index::Markdown.render` (editors are not fully trusted). An unset
  access level or login method is shown, never hidden. `/api/v1/index` feeds an extension that may be old: add fields,
  never rename or remove without bumping its `VERSION`. Content is data: change db/seeds/index only for what a fresh
  database should start with.
- **Never weaken the sign-in rules without the user's explicit permission**: tenant check, session lifetimes,
  admin re-authentication, the admin network check, PKCE/state/nonce. Propose the change instead.
