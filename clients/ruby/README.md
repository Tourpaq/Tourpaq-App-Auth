# tourpaq_auth

The Ruby client for **Tourpaq Auth** (auth.app.journeybooking.eu, the issuer), shared by the journeybooking Rails apps
(the auth app's SPECS.md §13). It speaks the protocol in SPECS.md §7–§10:

| Part | What it does |
| --- | --- |
| `TourpaqAuth::Client`, `TourpaqAuth::IdToken` | OIDC login: discovery and JWKS (cached 1 h, refetched once on an unknown `kid`), authorization URL with PKCE `S256` + `state` + `nonce`, code exchange with `client_secret_basic`, ID token verification (signature, `iss`, `aud`, `exp`, `iat`, `nonce`) → `TourpaqAuth::Login` |
| `TourpaqAuth::Access` | `check(sub)`: the user's access and role (`GET /api/v1/access/:sub`), cached for `max-age`, with the grace period during an outage. `members(etag:)` / `sync_members`: everybody with access (`GET /api/v1/access`, ETag) |
| `TourpaqAuth::Tokens` | `introspect(token)`: personal (`tpa_…`) and extension (`tpx_…`) tokens (`POST /oauth/introspect`), cached 60 s under the token's SHA-256 |
| `TourpaqAuth::Rails::AccessCheck` | Controller concern: re-checks the signed-in user every 5 minutes; ends the session or applies a changed role through your hooks |
| `TourpaqAuth::Rails::BearerToken` | Controller concern: `Authorization: Bearer`, introspected, exposed as `tourpaq_auth_token` |
| `TourpaqAuth::Catalogue` | `push(entries)`: a permission app's permission catalogue (`PUT /api/v1/catalogue`, SPECS.md §23.2) |
| `TourpaqAuth::Permissions` | `roles`, `permissions`, `permission?(key)`, `role?(name)` on every result above (permission apps) |
| `TourpaqAuth::TestSupport::FakeProvider` | A fake auth app for your tests, no network |

Its only dependency is `jwt` (~> 2.9, as the IRM). HTTP is plain `Net::HTTP`. The Rails parts are loaded on
first use, so the gem also works outside Rails.

## Configuration

Read from the environment by `TourpaqAuth.configure` (or on first use):

| Variable | Default | |
| --- | --- | --- |
| `LOGIN_ISSUER` | — | `https://auth.app.journeybooking.eu`, exactly (the `iss` of every ID token, and where browsers are sent) |
| `LOGIN_INTERNAL_URL` | — | Optional back-channel base URL, e.g. `http://auth:3050` on a shared Docker network or `http://host.docker.internal:3050` in local testing. When set, discovery is fetched there and the server-to-server calls (token, JWKS, userinfo, introspection, revocation, the access API, the catalogue push) go there; the authorization redirect, the end-session URL and the `iss` check stay on `LOGIN_ISSUER`. The auth app must list that host in its `AUTH_INTERNAL_HOSTS` (gem 0.3.0) |
| `LOGIN_CLIENT_ID` | — | The app's web client, e.g. `irm-web` |
| `LOGIN_CLIENT_SECRET` | — | Its secret (shown once in the auth app's admin UI) |
| `LOGIN_SCOPES` | `openid email profile` | |
| `LOGIN_ACCESS_CACHE_SECONDS` | `300` | How long an access answer is used, and how often the concern re-checks. The API's own `max-age` wins when shorter |
| `LOGIN_GRACE_HOURS` | `24` | How long the last known access answer stands in while the auth app cannot be reached |
| `LOGIN_ROLE_CLAIM` | from the client id | The ID token claim with the role. `irm-web` → `irm_role`, `azure-cost-web` → `azure_cost_role`. A permission app's list: `dashboard_roles` (read from `<app>_roles` when this claim is absent) |
| `LOGIN_PERMISSIONS_CLAIM` | from the client id | A permission app's permissions claim: `dashboard-web` → `dashboard_permissions` |
| `LOGIN_REDIRECT_URI` | — | Optional; or pass `redirect_uri:` to `begin_login` |

The gem is **off** (`TourpaqAuth.enabled?` false) until the first three are set. In an initializer:

```ruby
# config/initializers/tourpaq_auth.rb
TourpaqAuth.configure do |config|
  config.redirect_uri = "#{Rails.configuration.x.app_url}/sso/callback"
  # config.cache = Rails.cache            # the default when Rails.cache exists, else an in-memory store
  # config.grace_hours = 72               # e.g. the IRM, which must keep paging during an outage
end
```

The cache is anything with `read`, `write(key, value, expires_in:)` and `delete` (Rails.cache, Solid Cache, or
`TourpaqAuth::MemoryStore`). It holds plain hashes; tokens appear in it only as SHA-256 digests. With a
`:null_store` (Rails' test default) nothing is cached: every check asks the auth app, and only the access-check
concern's own session state bridges an outage. `with_tourpaq_auth` in tests uses a memory store.

## Login

```ruby
class SsoController < ApplicationController
  def start
    url, login = TourpaqAuth::Client.begin_login(redirect_uri: sso_callback_url) # extra: max_age:, prompt:, login_hint:
    session[:tourpaq_login] = login            # state, nonce, PKCE verifier (strings, cookie-safe)
    redirect_to url, allow_other_host: true
  rescue TourpaqAuth::Unavailable
    render :auth_down, status: :service_unavailable
  end

  def callback
    login = TourpaqAuth::Client.complete_login(session.delete(:tourpaq_login), params.permit(:code, :state, :error, :error_description).to_h)
    user = User.find_or_create_from_auth!(login)   # login.sub, .email, .name, .role, .sessions_valid_after, .claims
    start_new_session_for(user)
    tourpaq_auth_signed_in(login)              # from TourpaqAuth::Rails::AccessCheck
    redirect_to root_path
  rescue TourpaqAuth::LoginError, TourpaqAuth::Unavailable => e
    redirect_to login_path, alert: e.message   # messages never contain tokens or secrets
  end
end
```

`complete_login` checks the `state` (constant time) and that the login is younger than 10 minutes, exchanges
the code with the PKCE verifier, and verifies the ID token. Store `login.sub` next to the email: the email can
change, the `sub` never does. The lower-level calls (`authorization_url`, `exchange_code`, `IdToken.verify`,
`discovery`, `jwks`, `reachable?`, `end_session_url`) are there too, with the IRM's `Sso::Client` signatures.

## Re-checking access (SPECS.md §8.3)

```ruby
class ApplicationController < ActionController::Base
  include Authentication                     # your own sign-in first
  include TourpaqAuth::Rails::AccessCheck    # then this before_action

  private

  # Required: end the app's session (and render or redirect).
  # reason: :no_access, :signed_out_everywhere, :unavailable (grace period over) or :refused (the auth app
  # refused the check: this app or its client disabled there, or its secret deleted)
  def tourpaq_auth_end_session(reason, result)
    terminate_session
    redirect_to login_path, alert: "Your access to this app has changed. Sign in again."
  end

  # Optional: the auth app reports another role.
  def tourpaq_auth_apply_role(role, result)
    Current.user.update!(role: role)
  end
end
```

Every `LOGIN_ACCESS_CACHE_SECONDS` (5 minutes) per browser session it calls `TourpaqAuth::Access.check(sub)`:
no access → end; a session started before `sessions_valid_after` → end; another role → apply. When the auth app
is down (network failure, timeout, 5xx, 429), the session continues while the last confirmation is younger than
the grace period, and then ends. When the auth app *refuses* the check (401 `invalid_client` because this app or
its client is disabled there or the secret was deleted, 403, 400, a malformed answer), the session ends at once
with `:refused`: a refusal is not an outage.
The concern keeps its state in `session["tourpaq_auth"]`, filled by `tourpaq_auth_signed_in(login)`. Apps that
know better can override `tourpaq_auth_subject`, `tourpaq_auth_current_role` and
`tourpaq_auth_session_started_at`. Skip it for some actions with `skip_tourpaq_auth_access_check only: …`.

Directly:

```ruby
result = TourpaqAuth::Access.check(sub)  # .active?, .role, .sessions_valid_after, .checked_at, .stale?
# raises TourpaqAuth::Unavailable (outage, no usable last answer), TourpaqAuth::Refused (a refusal, e.g. a wrong
# secret or a disabled app; .status) or TourpaqAuth::Error (a malformed answer)
```

## Members sync (SPECS.md §8.2)

For apps that need people before their first login (the IRM's schedules). Run it every few minutes:

```ruby
class SyncAuthMembersJob < ApplicationJob
  def perform
    return unless TourpaqAuth.enabled?
    TourpaqAuth::Access.sync_members do |members|   # yields only when the list changed (ETag)
      User.sync_from_auth!(members)                  # each: sub, role, email, name, sessions_valid_after
    end                                               # users missing from the list have lost access
  end
end
```

`TourpaqAuth::Access.members(etag: previous)` is the lower-level call (`not_modified?`, `members`, `etag`).

## API and MCP tokens (SPECS.md §9.2)

```ruby
class Api::BaseController < ActionController::API
  include TourpaqAuth::Rails::BearerToken
  require_tourpaq_auth_token                                              # 401 without an active token
  require_tourpaq_auth_token write: true, only: %i[create update destroy]   # 403 for a read token

  private

  def current_user = @current_user ||= User.find_by!(auth_sub: tourpaq_auth_token.sub)
end
```

`tourpaq_auth_token` is a `TourpaqAuth::Tokens::Result` (`active?`, `token_type`, `sub`, `email`, `name`, `scope`,
`role`, `exp`, `app`, `read?`, `read_write?`). **The effective right is the scope capped by the role**: map your
roles yourself, e.g. `token.read_write? && %w[responder editor admin].include?(token.role)`. An outage is a 503
with `Retry-After`; override `tourpaq_auth_token_refused(reason)` / `tourpaq_auth_token_unavailable` to answer
differently. Directly: `TourpaqAuth::Tokens.introspect(token)`.

## Permission apps (SPECS.md §23.2, §23.3)

An app registered in the auth app with **multiple roles** (the Dashboard) gets, for each user, the names of the roles
they hold and the **sorted union of those roles' permissions** (`"*"` = everything), and never a single `role`. Single-role
apps (IRM, index) see no change: their `roles` is `[role]` and `permissions` is `[]`.

Every result has the same three things (`TourpaqAuth::Permissions`):

```ruby
login = TourpaqAuth::Client.complete_login(session.delete(:tourpaq_login), params…)  # TourpaqAuth::Login
login.role                     # nil: the role claim is a list
login.roles                    # ["Finance readers", "Support"]       (claim LOGIN_ROLE_CLAIM, e.g. dashboard_roles)
login.permissions              # ["management:finance:view", "module:customers:view"]  (claim dashboard_permissions)
login.permission?("module:customers:view")   # true, also through "*"
login.role?("Support")

TourpaqAuth::Access.check(sub)            # .active?, .roles, .permissions, .permission?(key); role nil
TourpaqAuth::Access.sync_members { |members| … }   # each member: sub, email, name, roles, permissions, sessions_valid_after
TourpaqAuth::Tokens.introspect(token)     # .scope ("public" / "all"), .scope?("all"), .roles, .permissions, .permission?(key)
```

Configuration: `LOGIN_CLIENT_ID=dashboard-web`, `LOGIN_ROLE_CLAIM=dashboard_roles` (optional: `dashboard_roles` is also
found without it), `LOGIN_PERMISSIONS_CLAIM` only if the claim is not `dashboard_permissions`.

**Keeping permissions current.** The access-check concern re-checks every 5 minutes and calls an optional hook when
the roles or permissions changed since the session last saw them (it keeps only a short digest in the session):

```ruby
def tourpaq_auth_apply_permissions(roles, permissions, result)
  Current.user.update!(auth_permissions: permissions)   # wherever the app keeps them for permit?
end
```

Store `login.permissions` the same way at sign-in. The members sync gives `member.permissions` too.

**The catalogue push.** At boot or deploy the app tells the auth app every permission it checks; the auth app's role
editor shows them as checkboxes grouped by `group`, and flags role keys that are no longer in it. Each push replaces
the catalogue:

```ruby
# config/initializers/tourpaq_auth.rb (after configure), or a deploy task
Rails.application.config.after_initialize do
  next unless TourpaqAuth.enabled? && Rails.env.production?
  entries = Permissions.catalog.map { { key: _1.key, label: I18n.t(_1.label_key), group: I18n.t(_1.group_key) } }
  result = TourpaqAuth::Catalogue.push(entries)   # PUT /api/v1/catalogue as the web client (HTTP Basic)
  Rails.logger.warn("Roles with unknown permissions: #{result.unknown}") if result.unknown.any?
rescue TourpaqAuth::Error => e
  Rails.logger.error("Catalogue push failed: #{e.message}")      # never stop the boot for it
end
```

Entries are hashes (`key`, `label`, `group` or `group_label`) or objects with `key` (and `label`, `group`). The answer
is a `TourpaqAuth::Catalogue::Result`: `app`, `count`, `added`, `removed`, `changed` (keys) and `unknown`
(`{ "Support" => ["old:key"] }`). Errors: `TourpaqAuth::Unavailable` (outage), `TourpaqAuth::Refused` (credentials, or a
malformed list: `status` 400 with the reason).

**Token scopes.** Each app has its own ordered scopes (the Dashboard's `public` < `all`); the token's is in
`token.scope`, and the app decides what each means. In an API controller:

```ruby
require_tourpaq_auth_token                                   # any active token
require_tourpaq_auth_token scope: "all", only: :internal     # 403 insufficient_scope (scope="all") otherwise
# and per record: tourpaq_auth_token.permission?("module:customers:view")
```

## Testing your app

```ruby
# test/test_helper.rb
require "tourpaq_auth/test_support"
class ActiveSupport::TestCase
  include TourpaqAuth::TestSupport::Helpers
end

# a test
with_tourpaq_auth(client_id: "irm-web") do |provider|
  sub = provider.add_user(email: "jjr@tourpaq.com", role: "responder")
  post sso_login_path
  get sso_callback_path(provider.authorize(response.location, sub: sub))  # plays /oauth/authorize
  assert_response :redirect

  provider.remove_access(sub)          # also: set_role, disable_user, sign_out_everywhere
  travel 6.minutes
  get root_path                        # the access check ends the session

  token = provider.issue_token(sub: sub, scope: "read_write")
  get api_incidents_path, headers: { "Authorization" => "Bearer #{token}" }

  provider.reachable = false           # the auth app is down
end
```

For a permission app:

```ruby
with_tourpaq_auth(client_id: "dashboard-web", multiple_roles: true, token_scopes: %w[public all]) do |provider|
  sub = provider.add_user(email: "x@tourpaq.com", roles: [ "Support" ], permissions: %w[module:customers:view])
  provider.set_roles(sub, [ "Administrators" ], permissions: [ "*" ])   # also set_permissions, remove_access
  token = provider.issue_token(sub: sub, scope: "all")                  # lowest scope by default; extension: highest
  TourpaqAuth::Catalogue.push(entries)
  provider.catalogue                    # the last push: [{ "key", "label", "group" }]; catalogue_pushes counts them
  provider.catalogue_status = 400       # refuse pushes
end
```

The fake answers discovery, JWKS, `/oauth/token` (checks `client_secret_basic`, PKCE and the redirect URI),
`/api/v1/access(/:sub)` (with `Cache-Control: max-age` and ETags), `/oauth/introspect` and `PUT /api/v1/catalogue`, through the gem's HTTP
seam (`TourpaqAuth.config.http`). It signs ID tokens with its own RSA key and can `rotate_key!` and
`forge_with_other_key!`. Status overrides (`token_status`, `access_status`, `members_status`,
`introspect_status`) simulate errors. `with_tourpaq_auth` uses a fresh in-memory cache and restores the previous
configuration afterwards.

## Adding it to an app

1. From the auth app: `bin/sync-client ../Tourpaq-App-IRM` copies the gem (lib, gemspec, README; no tests) to
   `vendor/gems/tourpaq_auth` in the app. Run it again after every change to the gem, and commit the copy in the app.
2. In the app's `Gemfile`: `gem "tourpaq_auth", path: "vendor/gems/tourpaq_auth"`, then
   `bin/docker-dev bundle install`.
3. In the app's `Dockerfile`, copy the vendored gem before `bundle install`, or the build cannot find it:

   ```dockerfile
   COPY Gemfile Gemfile.lock ./
   COPY vendor/gems ./vendor/gems
   RUN bundle install && …
   ```
4. Set `LOGIN_ISSUER`, `LOGIN_CLIENT_ID`, `LOGIN_CLIENT_SECRET` (Coolify; `.env` locally), add the initializer,
   the login controller, the two concerns and, where needed, the members-sync job (above).
5. Filter `token`, `code`, `client_secret` and `Authorization` from the app's logs
   (`config.filter_parameters`), as the auth app does.

## Developing the gem

The host Ruby is not used. The tests run in Docker (`ruby:4.0.7-slim` plus a compiler, image
`tourpaq-auth-client-test`, gems in the `tourpaq_auth_client_bundle` volume):

```sh
clients/ruby/bin/docker-test                                                  # bundle install + all tests
clients/ruby/bin/docker-test bundle exec ruby -Ilib -Itest test/access_test.rb  # one file
```

`actionpack` is a development dependency only, to test the controller concerns.

### Protocol notes

- The authorization API and introspection are called at the fixed paths of SPECS.md §7.1 under `LOGIN_ISSUER`
  (`/api/v1/access`, `/api/v1/access/:sub`, `/oauth/introspect`), or under `LOGIN_INTERNAL_URL` when it is set, not
  through discovery, so an access check during an outage needs no discovery fetch.
- `LOGIN_INTERNAL_URL` (0.3.0, SPECS.md §24.1): `Configuration#backchannel_endpoint(path)` and `#backchannel_url(url)`
  (the issuer prefix of a discovery URL swapped for the internal URL) are the only places a server-to-server URL is
  built. The discovery document is still checked against `LOGIN_ISSUER`, and so is every ID token's `iss`.
- `sessions_valid_after` (ID token, access API, members list) is Unix seconds **rounded up** by the auth app, and
  `Result#session_revoked?(started_at)` ends a session whose start (whole seconds) is before it, so a session that
  started in the same second as a sign out everywhere ends too. The fake provider rounds up the same way (0.3.1).
- `GET /api/v1/access` is read as `{ "members": [ … ] }`; a bare array, or `{ "users": [ … ] }`, is accepted too.
- The HTTP seam (`config.http`) is called as `call(method, url, form:, headers:, timeout:)`, plus `body:` only for the
  catalogue push (`:put` with a JSON body), so a seam written for 0.1 keeps working for everything else.
- 5xx, 429 and network failures count as an outage (grace period); 401/403 and other refusals raise
  `TourpaqAuth::Refused` (a `TourpaqAuth::Error`, with `status`). The access-check concern applies the grace period
  only to an outage: a refusal, or a malformed answer, ends the session (`:refused`) and is logged as an error.
- `TourpaqAuth::Tokens.cached?(token)` says whether an introspection answer is cached, so an app can spend a
  per-address budget only on tokens that would reach the auth app (the IRM does, against random-token floods).
