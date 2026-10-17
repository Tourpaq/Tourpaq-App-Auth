# Sign-in with Microsoft Entra ID (SPECS.md §3) through omniauth-entra-id, tightened in
# lib/omniauth/strategies/tourpaq_entra_id.rb (PKCE, nonce, JWKS signature, tenant check).
#
# - Start: POST /auth/entra_id only, with the CSRF token (omniauth-rails_csrf_protection).
# - Callback: /auth/entra_id/callback on the auth host, handled by OmniauthCallbacksController#entra_id;
#   failures go to its #failure action. The redirect_uri sent to Entra is ENTRA_REDIRECT_URI (SPECS.md §24.2):
#   while the registration only has home.app's callback, the Dashboard forwards that GET to this one.
# - Development and tests use the fake identity provider (SPECS.md §3.4, Dev::SignInsController)
#   and OmniAuth's test mode (test/support/entra_helpers.rb).
require Rails.root.join("lib/omniauth/strategies/tourpaq_entra_id")
require Rails.root.join("lib/rack_ext/auth_host_only")

auth = Rails.application.config.x.auth

Rails.application.config.middleware.use AuthHostOnly
Rails.application.config.middleware.use OmniAuth::Builder do
  provider OmniAuth::Strategies::TourpaqEntraId,
    client_id: auth.entra_client_id || "not-configured",
    client_secret: auth.entra_client_secret || "not-configured",
    tenant_id: auth.entra_tenant_id || "not-configured",
    scope: "openid profile email"
end

OmniAuth.config.allowed_request_methods = %i[post]
OmniAuth.config.full_host = auth.app_url # never the request's host; the redirect_uri itself: ENTRA_REDIRECT_URI
OmniAuth.config.logger = Rails.logger
OmniAuth.config.failure_raise_out_environments = [] # failures render our page in development too
OmniAuth.config.on_failure = ->(env) { OmniauthCallbacksController.action(:failure).call(env) }
