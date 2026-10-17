# One app, three hosts (SPECS.md §24.1). Each file under config/routes/ is constrained to its host:
#   auth.rb   AUTH host (APP_URL, the issuer): Entra sign-in, "waiting for access", sign out
#   oauth.rb  AUTH host: /oauth/authorize, /oauth/logout; back-channel (AUTH and AUTH_INTERNAL_HOSTS):
#             discovery, JWKS, /oauth/token, userinfo, revoke, introspect
#   api.rb    back-channel: the authorization API /api/v1/* (access, catalogue)
#   index.rb  INDEX host only: the index (launcher placeholder), profile, tokens, /sso/callback, sign out
#   admin.rb  ADMIN host only: admin UI, /sso/callback, sign out
#   dev.rb    development and test only: the fake identity provider
# A route that exists on one host is a 404 on the others (no redirect). On the internal hosts only the
# back-channel answers (InternalHostGate). Only the health checks answer on any host.
Rails.application.routes.draw do
  # Liveness (no database query) for Coolify, and readiness (database) for monitoring (§15).
  get "up" => "rails/health#show", as: :rails_health_check
  get "up/ready" => "health#ready", as: :readiness_check

  draw :auth
  draw :oauth
  draw :api
  draw :index
  draw :admin
  draw :dev if Rails.env.local?
end
