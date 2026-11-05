# The authorization API (SPECS.md §8), for the apps' web clients (HTTP Basic). Back-channel: on the AUTH
# host and on AUTH_INTERNAL_HOSTS (§24.1).
#   GET /api/v1/access/:sub   one user's access to the calling app
#   GET /api/v1/access        everybody with access to the calling app (ETag)
#   PUT /api/v1/catalogue     the calling app's permission catalogue (§23.2), replaced
#   GET /api/v1/config…       this app's access setup for its admins, through the MCP Gateway (§25.7; Bearer
#                             tpe_auth-config_, not HTTP Basic)
constraints(AuthHosts::BackChannel) do
  scope "api/v1", module: "api/v1", as: :api_v1, defaults: { format: :json } do
    get "access" => "access#index", as: :access_index
    get "access/:sub" => "access#show", as: :access, constraints: { sub: %r{[^/]+} }
    put "catalogue" => "catalogues#update", as: :catalogue

    segment = %r{[^/]+} # an email or a group name may hold dots
    get "config" => "config#index", as: :config
    get "config/whoami" => "config#whoami", as: :config_whoami
    get "config/apps/:slug" => "config#show_app", as: :config_app, constraints: { slug: segment }
    get "config/users/:user" => "config#show_user", as: :config_user, constraints: { user: segment }
    get "config/groups/:name" => "config#show_group", as: :config_group, constraints: { name: segment }
  end
end
