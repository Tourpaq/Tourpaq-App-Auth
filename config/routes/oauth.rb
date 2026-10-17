# The OIDC provider (SPECS.md §7, §10, §24.1). Controllers in app/controllers/oauth/.
#
# AUTH host only (the browser):
#   GET  /oauth/authorize                    code flow (browser; needs an auth session)
#   GET  /oauth/logout (POST: confirmation)  RP-initiated logout
# Back-channel, on the AUTH host and on AUTH_INTERNAL_HOSTS (servers):
#   GET  /.well-known/openid-configuration   discovery (issuer = APP_URL, whatever the Host header)
#   GET  /oauth/jwks                         current and previous signing keys
#   POST /oauth/token                        authorization_code, refresh_token
#   GET  /oauth/userinfo (also POST)         Bearer access token
#   POST /oauth/revoke                       RFC 7009
#   POST /oauth/introspect                   RFC 7662, for the apps' web clients (§9.2)
constraints(AuthHosts::Auth) do
  scope "oauth", module: :oauth, as: :oauth do
    get "authorize" => "authorizations#new", as: :authorize
    get "logout" => "logouts#show", as: :logout
    post "logout" => "logouts#create"
  end
end

constraints(AuthHosts::BackChannel) do
  get ".well-known/openid-configuration" => "oauth/discovery#show", as: :openid_configuration
  scope "oauth", module: :oauth, as: :oauth do
    get "jwks" => "discovery#jwks", as: :jwks
    post "token" => "tokens#create", as: :token
    match "userinfo" => "userinfo#show", via: %i[get post], as: :userinfo
    post "revoke" => "revocations#create", as: :revoke
    post "introspect" => "introspections#create", as: :introspect
  end
end
