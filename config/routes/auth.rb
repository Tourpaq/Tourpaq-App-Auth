# AUTH host (APP_URL, the issuer): Entra sign-in, "waiting for access", sign out (SPECS.md §3, §24.1).
# The index, profile and tokens are on the INDEX host (index.rb).
constraints(AuthHosts::Auth) do
  # A signed-in user goes on to the index host ("waiting for access" while they have nothing); sign-in otherwise.
  root "root#show"

  # Sign-in: POST /auth/entra_id is OmniAuth's (config/initializers/omniauth.rb); it comes back here, as a
  # GET (response_mode=query), also when the Dashboard forwards it from home.app (§24.2).
  get "sign_in" => "sessions#new", as: :sign_in
  match "auth/entra_id/callback" => "omniauth_callbacks#entra_id", via: %i[get post], as: :entra_id_callback
  resource :session, only: :destroy # DELETE /session: sign out (§3.3)

  # A signed-in user without any access yet (§3.2, §11.1).
  get "waiting" => "waiting#show", as: :waiting
end
