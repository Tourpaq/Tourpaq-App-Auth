# ADMIN host (ADMIN_URL) only (SPECS.md §11.2, §24.1). Paths are at the host's root (/users, /apps …);
# controllers live in Admin::, route helpers are admin_*. None of this exists on the other hosts.
constraints(AuthHosts::Admin) do
  scope module: :admin, as: :admin do
    root "dashboard#show"

    # The admin host's OIDC callback as client "admin" (protocol milestone owns this route and
    # Admin::SsoController) and its sign out.
    get "sso/callback" => "sso#callback", as: :sso_callback
    resource :session, only: :destroy

    # Users (§11.2): pending first; the user page has access, grants, groups, sessions, tokens,
    # extensions and the actions.
    resources :users, only: %i[index show new create] do
      member do
        post :disable
        post :enable
        post :make_admin
        post :remove_admin
        post :sign_out_everywhere
      end
      resources :sessions, only: :destroy, controller: "user_sessions"
      resources :extensions, only: :destroy, controller: "user_extensions"
      post "groups" => "group_members#create", as: :groups, defaults: { back: "user" } # group_id in the form
    end

    # Groups: members and grants per app.
    resources :groups do
      resources :members, only: %i[create destroy], controller: "group_members"
    end

    # Grants to a user or a group (POST sets or changes, DELETE removes), audited with the
    # before/after effective roles (GrantChange).
    resources :grants, only: %i[create destroy]

    # Apps: details, roles (add, edit, remove, reorder with a preview), clients and their secrets,
    # members (effective roles and their source). A multiple-roles app's role editor is roles#edit (§23.2).
    resources :apps, only: %i[index show new create edit update] do
      get :members, on: :member
      resources :roles, only: %i[create edit update destroy], controller: "app_roles" do
        collection do
          get :reorder               # preview: whose effective role changes
          patch :reorder, action: :apply_reorder
        end
      end
      resources :clients, only: %i[show new create edit update] do
        resources :secrets, only: %i[create destroy], controller: "client_secrets"
      end
    end

    resources :tokens, only: %i[index destroy], controller: "personal_tokens"

    # The index content (SPECS.md §24.3), as WWW's /admin: /index (overview with the gaps), entries with their links,
    # sections with their visibility, the two vocabularies, docs and doc sections, site settings. Controllers in
    # Admin::IndexContent::, helpers admin_index_*. Every change is audited (index.*).
    scope "index", module: :index_content, as: :index do
      root "dashboard#show"
      resources :entries, except: :show
      resources :sections, except: :show
      resources :access_levels, except: :show
      resources :login_methods, except: :show
      resources :doc_sections, except: :show
      resources :docs, except: :show
      resource :site, only: %i[edit update]
    end
    get "access" => "access_matrix#show", as: :access_matrix # also .csv
    resources :audit_events, only: :index, path: "audit"
  end
end
