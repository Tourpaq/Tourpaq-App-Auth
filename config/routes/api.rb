# The authorization API (SPECS.md §8), for the apps' web clients (HTTP Basic). Back-channel: on the AUTH
# host and on AUTH_INTERNAL_HOSTS (§24.1).
#   GET /api/v1/access/:sub   one user's access to the calling app
#   GET /api/v1/access        everybody with access to the calling app (ETag)
#   PUT /api/v1/catalogue     the calling app's permission catalogue (§23.2), replaced
constraints(AuthHosts::BackChannel) do
  scope "api/v1", module: "api/v1", as: :api_v1, defaults: { format: :json } do
    get "access" => "access#index", as: :access_index
    get "access/:sub" => "access#show", as: :access, constraints: { sub: %r{[^/]+} }
    put "catalogue" => "catalogues#update", as: :catalogue
  end
end
