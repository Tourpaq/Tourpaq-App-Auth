# Development and test only (drawn when Rails.env.local?): the fake identity provider (SPECS.md §3.4) on
# the auth host, and a shortcut into the admin host that skips its OIDC round trip.
constraints(AuthHosts::Auth) do
  get "dev/sign_in" => "dev/sign_ins#new", as: :dev_sign_in
  post "dev/sign_in" => "dev/sign_ins#create"
end

constraints(AuthHosts::Admin) do
  get "dev/admin_sign_in" => "dev/admin_sign_ins#new", as: :dev_admin_sign_in
  post "dev/admin_sign_in" => "dev/admin_sign_ins#create"
end
