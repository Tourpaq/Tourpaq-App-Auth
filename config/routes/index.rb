# INDEX host (INDEX_URL) only (SPECS.md §24.1, §24.3). Paths at the host's root; controllers in Index::
# (Index::BaseController: IndexAuthentication, layout "index"), route helpers index_*. None of this exists on
# the other hosts. The index host signs in through the auth host as the internal OIDC client "index".
#
# The index content (§24.3) keeps WWW's paths, so old www.app links work behind the www.app → index.app redirect:
#   /                    the front page (Index::HomeController)
#   /search (.json)      search; the JSON is the viewer's index for the as-you-type box
#   /groups/:id          a section;  /apps/:id  an entry's details page
#   /docs/:section/:slug, /docs/:slug   docs
#   /api/v1/index        the index for the browser extension (Bearer tpx_index_… or the index session). Not the
#                        back-channel: /api/v1/* on the auth and internal hosts is api.rb, this is the index host.
constraints(AuthHosts::Index) do
  scope module: :index, as: :index do
    root "home#show"
    get "search" => "search#index", as: :search
    get "groups/:id" => "sections#show", as: :section
    get "apps/:id" => "entries#show", as: :entry
    get "docs/:section/:slug" => "docs#show", as: :doc
    get "docs/:slug" => "docs#show", as: :root_doc
    get "api/v1/index" => "api/index#show", as: :api_index, defaults: { format: :json }

    # The OIDC callback as client "index", the sign out, and the page after it.
    get "sso/callback" => "sso#callback", as: :sso_callback
    resource :session, only: :destroy
    get "signed_out" => "sessions#signed_out", as: :signed_out

    # Profile (§11.1): name and email, my access, my sessions, my signed-in extensions.
    resource :profile, only: :show, controller: "profile"
    scope "profile", module: :profile, as: :profile do
      resources :sessions, only: :destroy      # DELETE /profile/sessions/:id    end one of my sessions
      resources :extensions, only: :destroy    # DELETE /profile/extensions/:id  sign out an extension (its chain)
    end

    # Tokens (§9.1): personal API/MCP tokens, listed, created (shown once) and revoked here.
    resources :tokens, only: %i[index create destroy]
  end
end
